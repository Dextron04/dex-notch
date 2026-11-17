"""Hosted accounts: users, billing status, and the one place a user id becomes a directory.
SQLite, one short-lived connection per call (the HTTP server is threaded). Billing is a placeholder: see `grant`."""
import os, re, secrets, shutil, sqlite3, time
from contextlib import closing
from pathlib import Path
from typing import Optional

SCHEMA = """
CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, created_at REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending', status_at REAL);
CREATE TABLE IF NOT EXISTS billing(user_id TEXT PRIMARY KEY REFERENCES users(id), stripe_customer_id TEXT, stripe_sub_id TEXT,
  plan TEXT, period_end REAL, event_ts REAL);
CREATE INDEX IF NOT EXISTS billing_customer ON billing(stripe_customer_id);
CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
  created_at REAL NOT NULL, last_seen REAL, revoked INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id);
CREATE TABLE IF NOT EXISTS stripe_events(id TEXT PRIMARY KEY, received REAL NOT NULL);
CREATE TABLE IF NOT EXISTS clients(id TEXT PRIMARY KEY, name TEXT NOT NULL, redirect_uris TEXT NOT NULL, created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS grants(hash TEXT PRIMARY KEY, kind TEXT NOT NULL, user_id TEXT NOT NULL REFERENCES users(id),
  client_id TEXT NOT NULL, data TEXT, exp REAL NOT NULL);
CREATE INDEX IF NOT EXISTS grants_user ON grants(user_id);
CREATE TABLE IF NOT EXISTS login_links(hash TEXT PRIMARY KEY, email TEXT NOT NULL, next TEXT, exp REAL NOT NULL);
CREATE TABLE IF NOT EXISTS links(code TEXT PRIMARY KEY, secret_hash TEXT NOT NULL UNIQUE, name TEXT NOT NULL, user_id TEXT, token TEXT, exp REAL NOT NULL);  -- see link.py
CREATE TABLE IF NOT EXISTS waitlist(email TEXT PRIMARY KEY, note TEXT NOT NULL DEFAULT '', created REAL NOT NULL, invited_at REAL);
CREATE TABLE IF NOT EXISTS invites(email TEXT PRIMARY KEY, added REAL NOT NULL);
CREATE TABLE IF NOT EXISTS sessions(hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), exp REAL NOT NULL);
"""
STATUSES = {"pending", "active", "past_due", "canceled", "deleted"}
FREE_QUOTA, PAID_QUOTA = 100 * 1024 * 1024, 500 * 1024 * 1024
OWNER_PLAN = "owner"   # set by `grant --plan owner`: no storage limit
USABLE = {"pending", "active", "past_due"}   # a free account (pending) can use memory, within the free quota; canceled and deleted accounts cannot
ENTITLED = {"active", "past_due"}  # past_due = Stripe is still retrying the card; it flips to canceled when the retries end
USER_ID = re.compile(r"u_[A-Za-z0-9_-]{22}")
EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")

class Store:
    def __init__(self, root: Path):
        """`root` holds hosted.db and data/<user_id>/Vault."""
        self.root = Path(root); self.root.mkdir(parents=True, exist_ok=True)
        self.db = self.root / "hosted.db"
        with self.conn() as c:
            c.executescript(SCHEMA)
            try: os.chmod(self.db, 0o600)   # the account database is for this user only
            except OSError: pass
            if "status_at" not in [r["name"] for r in c.execute("PRAGMA table_info(users)")]: c.execute("ALTER TABLE users ADD COLUMN status_at REAL")  # databases from before retention existed

    def conn(self):
        c = sqlite3.connect(self.db, timeout=10); c.row_factory = sqlite3.Row
        c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA foreign_keys=ON")
        return closing_commit(c)

    def create_user(self, email: str) -> str:
        email = (email or "").strip().lower()
        if not EMAIL.fullmatch(email) or len(email) > 254: raise ValueError("invalid email")
        uid = "u_" + secrets.token_urlsafe(16)  # 128 random bits; never derived from the email
        try:
            with self.conn() as c: c.execute("INSERT INTO users(id,email,created_at) VALUES(?,?,?)", (uid, email, time.time()))
        except sqlite3.IntegrityError: raise ValueError("email already registered")
        return uid

    def email(self, uid: str) -> Optional[str]:
        with self.conn() as c: r = c.execute("SELECT email FROM users WHERE id=?", (uid,)).fetchone()
        return r["email"] if r else None

    def by_email(self, email: str) -> Optional[str]:
        with self.conn() as c: r = c.execute("SELECT id FROM users WHERE email=?", ((email or "").strip().lower(),)).fetchone()
        return r["id"] if r else None

    def status(self, uid: str) -> Optional[str]:
        with self.conn() as c: r = c.execute("SELECT status FROM users WHERE id=?", (uid,)).fetchone()
        return r["status"] if r else None

    def set_status(self, uid: str, status: str) -> None:
        if status not in STATUSES: raise ValueError("unknown status")
        with self.conn() as c:
            if not c.execute("UPDATE users SET status=?, status_at=? WHERE id=?", (status, time.time(), uid)).rowcount: raise KeyError(uid)

    def delete_account(self, uid: str) -> None:
        """Erases a user: credentials, devices, sessions and every note. The users row stays as a tombstone (id, status) with the email freed, so the same
        address can sign up again and late Stripe events have nothing to revive. Safe to run twice (a half-finished delete is finished by the second run)."""
        if not USER_ID.fullmatch(uid or ""): raise ValueError("invalid user id")
        with self.conn() as c:
            r = c.execute("SELECT email FROM users WHERE id=?", (uid,)).fetchone()
            if not r: raise KeyError(uid)
            for t in ("devices", "grants", "sessions", "links"): c.execute("DELETE FROM %s WHERE user_id=?" % t, (uid,))
            for t in ("login_links", "waitlist", "invites"): c.execute("DELETE FROM %s WHERE email=?" % t, (r["email"],))   # the address itself goes too, not only the account
            c.execute("UPDATE users SET status='deleted', status_at=?, email=? WHERE id=?", (time.time(), "deleted-%s@invalid" % uid, uid))
        shutil.rmtree(self.root / "data" / uid, ignore_errors=True)

    def canceled_before(self, ts: float) -> list:
        """Users whose subscription ended before `ts` (unix) and who never came back: candidates for the retention purge."""
        with self.conn() as c: return [r["id"] for r in c.execute("SELECT id FROM users WHERE status='canceled' AND status_at IS NOT NULL AND status_at<?", (ts,))]

    # -- closed beta: who may create an account
    def invite(self, email: str) -> str:
        email = (email or "").strip().lower()
        if not EMAIL.fullmatch(email) or len(email) > 254: raise ValueError("invalid email")
        with self.conn() as c: c.execute("INSERT OR IGNORE INTO invites VALUES(?,?)", (email, time.time()))
        return email

    def uninvite(self, email: str) -> None:
        with self.conn() as c: c.execute("DELETE FROM invites WHERE email=?", ((email or "").strip().lower(),))

    def invited(self, email: str) -> bool:
        with self.conn() as c: return bool(c.execute("SELECT 1 FROM invites WHERE email=?", ((email or "").strip().lower(),)).fetchone())

    def invites(self) -> list:
        with self.conn() as c: return [r["email"] for r in c.execute("SELECT email FROM invites ORDER BY added")]

    WAITLIST_CAP = 2000   # a public form must not be able to fill the disk

    def join_waitlist(self, email: str, note: str = "") -> bool:
        """True if the address is on the list afterwards (already there counts). False only when the list is full."""
        email = (email or "").strip().lower()
        if not EMAIL.fullmatch(email) or len(email) > 254: raise ValueError("invalid email")
        with self.conn() as c:
            if c.execute("SELECT 1 FROM waitlist WHERE email=?", (email,)).fetchone(): return True
            if c.execute("SELECT COUNT(*) FROM waitlist").fetchone()[0] >= self.WAITLIST_CAP: return False
            c.execute("INSERT INTO waitlist(email,note,created) VALUES(?,?,?)", (email, " ".join((note or "").split())[:300], time.time()))
        return True

    def waitlist(self) -> list:
        with self.conn() as c: return [dict(r) for r in c.execute("SELECT email,note,created,invited_at FROM waitlist ORDER BY created")]

    def mark_invited(self, email: str) -> None:
        with self.conn() as c: c.execute("UPDATE waitlist SET invited_at=? WHERE email=?", (time.time(), (email or "").strip().lower()))

    def remove_waitlist(self, email: str) -> None:
        with self.conn() as c: c.execute("DELETE FROM waitlist WHERE email=?", ((email or "").strip().lower(),))

    def user_count(self) -> int:
        with self.conn() as c: return c.execute("SELECT COUNT(*) FROM users WHERE status!='deleted'").fetchone()[0]

    def stats(self) -> dict:
        with self.conn() as c:
            by = {r["status"]: r["n"] for r in c.execute("SELECT status, COUNT(*) n FROM users GROUP BY status")}
            dev = c.execute("SELECT COUNT(*) FROM devices WHERE revoked=0").fetchone()[0]
        return {"users": by, "devices": dev, "db_bytes": self.db.stat().st_size}

    def entitled(self, uid: str) -> bool:
        """The gate every /mcp and /v1 call will check."""
        return self.status(uid) in ENTITLED

    def may_use(self, uid: str) -> bool:
        """The gate on uploads and the connector: free and paid accounts, not canceled or deleted ones. (`entitled` still means paid.)"""
        return self.status(uid) in USABLE

    def quota(self, uid: str) -> Optional[int]:
        """Bytes of notes the account may hold; None = no limit."""
        with self.conn() as c: r = c.execute("SELECT plan FROM billing WHERE user_id=?", (uid,)).fetchone()
        if r and r["plan"] == OWNER_PLAN: return None
        return PAID_QUOTA if self.entitled(uid) else FREE_QUOTA

    def grant(self, uid: str, plan: str = "placeholder") -> None:
        """Dev/manual override (the `grant` CLI): marks the user paid without Stripe. Real payments arrive through billing.apply_event."""
        self.set_status(uid, "active")
        with self.conn() as c:
            c.execute("INSERT INTO billing(user_id,plan) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET plan=excluded.plan", (uid, plan))

    def user_vault(self, uid: str) -> Path:
        """The only way to reach a user's notes. Every tool handler gets this Path as its `vault` and never sees another."""
        if not USER_ID.fullmatch(uid or ""): raise ValueError("invalid user id")
        if self.status(uid) is None: raise KeyError(uid)
        v = self.root / "data" / uid / "Vault"
        v.mkdir(parents=True, exist_ok=True)
        return v

class closing_commit:
    """sqlite3's own `with` commits but never closes; this does both."""
    def __init__(self, c): self.c = c
    def __enter__(self): return self.c
    def __exit__(self, et, *_):
        try: self.c.commit() if et is None else self.c.rollback()
        finally: self.c.close()
