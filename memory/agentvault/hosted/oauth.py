"""Hosted OAuth 2.1 + magic-link login, in SQLite. Same rules as remote/oauth.py (PKCE S256, hashed tokens, rotating refresh,
single-use codes) but every grant belongs to a user. Secrets are only ever stored as SHA-256 hashes."""
import base64, hashlib, hmac, json, secrets, time
from typing import Callable, List, Optional, Tuple
from urllib.parse import urlparse
from .store import Store

CODE_TTL, ACCESS_TTL, REFRESH_TTL, LINK_TTL, SESSION_TTL = 300, 3600, 30 * 86400, 900, 7 * 86400
ALLOWED_REDIRECT_HOSTS = ("chatgpt.com", "claude.ai", "claude.com")

class AuthError(Exception):
    pass

def _h(v: str) -> str:
    return hashlib.sha256(v.encode()).hexdigest()

def _pop(c, table: str, h: str, kind: Optional[str] = None):
    """Take a row exactly once: when two requests race, only the one whose DELETE removes the row gets it."""
    q, a = "WHERE hash=?" + (" AND kind=?" if kind else ""), (h, kind) if kind else (h,)
    r = c.execute("SELECT * FROM %s %s" % (table, q), a).fetchone()
    return r if r and c.execute("DELETE FROM %s %s" % (table, q), a).rowcount else None

class Auth:
    def __init__(self, store: Store, now: Callable[[], float] = time.time, allowed_hosts=ALLOWED_REDIRECT_HOSTS):
        self.store, self.now, self.allowed = store, now, tuple(allowed_hosts)

    def _gc(self, c) -> None:
        for t in ("grants", "login_links", "sessions"): c.execute("DELETE FROM %s WHERE exp<=?" % t, (self.now(),))

    # -- OAuth clients (dynamic registration)
    def register(self, redirect_uris: List[str], name: str) -> str:
        if not redirect_uris or not isinstance(redirect_uris, list): raise AuthError("redirect_uris required")
        for u in redirect_uris:
            p = urlparse(str(u))
            if p.scheme != "https" or (p.hostname or "") not in self.allowed: raise AuthError("redirect_uri not allowed: %s" % u)
        cid = "c_" + secrets.token_urlsafe(16)
        with self.store.conn() as c:
            c.execute("INSERT INTO clients VALUES(?,?,?,?)", (cid, str(name)[:80], json.dumps(redirect_uris), self.now()))
        return cid

    def client(self, cid: str) -> dict:
        with self.store.conn() as c: r = c.execute("SELECT * FROM clients WHERE id=?", (cid,)).fetchone()
        if not r: raise AuthError("unknown client")
        return {"name": r["name"], "redirect_uris": json.loads(r["redirect_uris"])}

    # -- magic-link login: proves the person owns the email; the account is created at this point, not before
    def start_login(self, email: str, nxt: Optional[str] = None) -> str:
        email = (email or "").strip().lower()
        if not email or len(email) > 254 or "@" not in email: raise AuthError("invalid email")
        token = secrets.token_urlsafe(32)
        with self.store.conn() as c:
            self._gc(c)
            c.execute("INSERT INTO login_links VALUES(?,?,?,?)", (_h(token), email, nxt, self.now() + LINK_TTL))
        return token

    def finish_login(self, token: str) -> Tuple[str, str, Optional[str]]:
        """Consumes the link. Returns (session token, user id, next path)."""
        with self.store.conn() as c:
            r = _pop(c, "login_links", _h(token or ""))
            if not r or r["exp"] <= self.now(): raise AuthError("this sign-in link is invalid or expired")
        uid = self.store.by_email(r["email"]) or self.store.create_user(r["email"])
        sess = secrets.token_urlsafe(32)
        with self.store.conn() as c: c.execute("INSERT INTO sessions VALUES(?,?,?)", (_h(sess), uid, self.now() + SESSION_TTL))
        return sess, uid, r["next"]

    def session_user(self, sess: str) -> Optional[str]:
        with self.store.conn() as c: r = c.execute("SELECT user_id, exp FROM sessions WHERE hash=?", (_h(sess or ""),)).fetchone()
        return r["user_id"] if r and r["exp"] > self.now() and self.store.status(r["user_id"]) not in (None, "deleted") else None

    def revoke_all(self, uid: str) -> None:
        """Sign out everywhere: browser sessions and every OAuth grant (so ChatGPT/Claude must re-authorize)."""
        with self.store.conn() as c:
            c.execute("DELETE FROM sessions WHERE user_id=?", (uid,)); c.execute("DELETE FROM grants WHERE user_id=?", (uid,))

    # -- OAuth grants
    def issue_code(self, cid: str, uid: str, redirect_uri: str, challenge: str) -> str:
        if redirect_uri not in self.client(cid)["redirect_uris"]: raise AuthError("redirect_uri mismatch")
        if not challenge: raise AuthError("code_challenge required")
        code = secrets.token_urlsafe(32)
        with self.store.conn() as c:
            self._gc(c)
            c.execute("INSERT INTO grants VALUES(?,?,?,?,?,?)", (_h(code), "code", uid, cid, json.dumps({"redir": redirect_uri, "ch": challenge}), self.now() + CODE_TTL))
        return code

    def _tokens(self, c, uid: str, cid: str) -> dict:
        a, r, t = secrets.token_urlsafe(32), secrets.token_urlsafe(32), self.now()
        c.execute("INSERT INTO grants VALUES(?,?,?,?,NULL,?)", (_h(a), "access", uid, cid, t + ACCESS_TTL))
        c.execute("INSERT INTO grants VALUES(?,?,?,?,NULL,?)", (_h(r), "refresh", uid, cid, t + REFRESH_TTL))
        return {"access_token": a, "token_type": "Bearer", "expires_in": ACCESS_TTL, "refresh_token": r}

    def exchange(self, code: str, cid: str, redirect_uri: str, verifier: str) -> dict:
        with self.store.conn() as c:  # the pop commits even when a check below fails: a code is single use no matter what
            rec = _pop(c, "grants", _h(code or ""), "code")
        if not rec or rec["exp"] <= self.now(): raise AuthError("invalid or expired code")
        d = json.loads(rec["data"])
        if rec["client_id"] != cid or d["redir"] != redirect_uri: raise AuthError("code does not match client")
        want = base64.urlsafe_b64encode(hashlib.sha256((verifier or "").encode()).digest()).rstrip(b"=").decode()
        if not hmac.compare_digest(want, d["ch"]): raise AuthError("PKCE verification failed")
        with self.store.conn() as c: return self._tokens(c, rec["user_id"], cid)

    def refresh(self, refresh_token: str, cid: str) -> dict:
        with self.store.conn() as c: rec = _pop(c, "grants", _h(refresh_token or ""), "refresh")
        if not rec or rec["exp"] <= self.now() or rec["client_id"] != cid: raise AuthError("invalid refresh token")
        with self.store.conn() as c: return self._tokens(c, rec["user_id"], cid)

    def check(self, access_token: str) -> Optional[str]:
        """The user id behind a valid access token, else None. Entitlement is a separate check (Store.entitled)."""
        with self.store.conn() as c: r = c.execute("SELECT user_id, exp FROM grants WHERE hash=? AND kind='access'", (_h(access_token or ""),)).fetchone()
        return r["user_id"] if r and r["exp"] > self.now() else None
