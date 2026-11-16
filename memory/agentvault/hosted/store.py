"""Hosted accounts: users, billing status, and the one place a user id becomes a directory.
SQLite, one short-lived connection per call (the HTTP server is threaded). Billing is a placeholder: see `grant`."""
import re, secrets, sqlite3, time
from contextlib import closing
from pathlib import Path
from typing import Optional

SCHEMA = """
CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, created_at REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending');
CREATE TABLE IF NOT EXISTS billing(user_id TEXT PRIMARY KEY REFERENCES users(id), stripe_customer_id TEXT, stripe_sub_id TEXT,
  plan TEXT, period_end REAL);
CREATE TABLE IF NOT EXISTS clients(id TEXT PRIMARY KEY, name TEXT NOT NULL, redirect_uris TEXT NOT NULL, created_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS grants(hash TEXT PRIMARY KEY, kind TEXT NOT NULL, user_id TEXT NOT NULL REFERENCES users(id),
  client_id TEXT NOT NULL, data TEXT, exp REAL NOT NULL);
CREATE INDEX IF NOT EXISTS grants_user ON grants(user_id);
CREATE TABLE IF NOT EXISTS login_links(hash TEXT PRIMARY KEY, email TEXT NOT NULL, next TEXT, exp REAL NOT NULL);
CREATE TABLE IF NOT EXISTS sessions(hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), exp REAL NOT NULL);
"""
STATUSES = {"pending", "active", "past_due", "canceled", "deleted"}
ENTITLED = {"active", "past_due"}  # ponytail: past_due gets the whole period, not a timed grace; add period_end logic with Stripe
USER_ID = re.compile(r"u_[A-Za-z0-9_-]{22}")
EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")

class Store:
    def __init__(self, root: Path):
        """`root` holds hosted.db and data/<user_id>/Vault."""
        self.root = Path(root); self.root.mkdir(parents=True, exist_ok=True)
        self.db = self.root / "hosted.db"
        with self.conn() as c: c.executescript(SCHEMA)

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

    def by_email(self, email: str) -> Optional[str]:
        with self.conn() as c: r = c.execute("SELECT id FROM users WHERE email=?", ((email or "").strip().lower(),)).fetchone()
        return r["id"] if r else None

    def status(self, uid: str) -> Optional[str]:
        with self.conn() as c: r = c.execute("SELECT status FROM users WHERE id=?", (uid,)).fetchone()
        return r["status"] if r else None

    def set_status(self, uid: str, status: str) -> None:
        if status not in STATUSES: raise ValueError("unknown status")
        with self.conn() as c:
            if not c.execute("UPDATE users SET status=? WHERE id=?", (status, uid)).rowcount: raise KeyError(uid)

    def entitled(self, uid: str) -> bool:
        """The gate every /mcp and /v1 call will check."""
        return self.status(uid) in ENTITLED

    def grant(self, uid: str, plan: str = "placeholder") -> None:
        """PLACEHOLDER for Stripe: marks the user paid. The webhook handler will replace the callers, and fill stripe_* and period_end."""
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
