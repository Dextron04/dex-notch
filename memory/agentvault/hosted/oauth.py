"""Hosted OAuth 2.1 + magic-link login, in SQLite. Same rules as remote/oauth.py (PKCE S256, hashed tokens, rotating refresh,
single-use codes) but every grant belongs to a user. Secrets are only ever stored as SHA-256 hashes."""
import base64, hashlib, hmac, json, secrets, time
from typing import Callable, List, Optional, Tuple
from urllib.parse import urlparse
from .. import seal
from ..remote.oauth import https_redirect_ok, plain_url
from .store import EMAIL, Store

CODE_TTL, ACCESS_TTL, REFRESH_TTL, LINK_TTL, SESSION_TTL = 300, 3600, 30 * 86400, 900, 7 * 86400
UNLOCKED_TTL = 12 * 3600   # a session that holds the vault key forgets it sooner than one that does not
ALLOWED_REDIRECT_HOSTS = ("chatgpt.com", "claude.ai", "claude.com")

class AuthError(Exception):
    pass

def is_loopback(uri: str) -> bool:
    """A command-line tool (Codex, Claude Code) receives its sign-in answer on a port of its own machine: http://127.0.0.1:PORT/... (RFC 8252). Only the machine itself, no other host."""
    if not plain_url(uri): return False
    p = urlparse(str(uri))
    try: p.port   # "127.0.0.1:80:80" or ":5!" has no real port; a browser won't open it either
    except ValueError: return False
    return p.scheme == "http" and (p.hostname or "") in ("127.0.0.1", "localhost", "::1") and p.username is None and p.password is None and not p.fragment

def redirect_ok(registered: List[str], uri: str, allowed=ALLOWED_REDIRECT_HOSTS) -> bool:
    """The address a client asks to be sent back to must be one it registered. For a loopback address the port may differ: the tool picks a free one each time."""
    if uri in registered: return is_loopback(uri) or https_redirect_ok(uri, allowed)   # also refuses a client registered before register() checked host and path
    if not is_loopback(uri): return False
    u = urlparse(uri)
    for r in registered:
        if is_loopback(r) and (urlparse(r).hostname, urlparse(r).path, urlparse(r).query) == (u.hostname, u.path, u.query): return True
    return False

def _h(v: str) -> str:
    return hashlib.sha256(v.encode()).hexdigest()

def _kek(token: str) -> bytes: return seal.kek_from_secret(token, b"oauth")

def _pop(c, table: str, h: str, kind: Optional[str] = None):
    """Take a row exactly once: when two requests race, only the one whose DELETE removes the row gets it."""
    q, a = "WHERE hash=?" + (" AND kind=?" if kind else ""), (h, kind) if kind else (h,)
    r = c.execute("SELECT * FROM %s %s" % (table, q), a).fetchone()
    return r if r and c.execute("DELETE FROM %s %s" % (table, q), a).rowcount else None

class Auth:
    def __init__(self, store: Store, now: Callable[[], float] = time.time, allowed_hosts=ALLOWED_REDIRECT_HOSTS, invite_only: bool = False, max_users: int = 0):
        """`invite_only`: only existing accounts and invited emails may sign in. `max_users` (0 = no cap): stops new accounts once that many exist."""
        self.store, self.now, self.allowed, self.invite_only, self.max_users = store, now, tuple(allowed_hosts), invite_only, max_users
        self.on_new_user: Optional[Callable[[str], None]] = None   # called with the email when a verified sign-in creates an account (the welcome mail)

    def may_join(self, email: str) -> Optional[str]:
        """None if this address may sign in (existing account, or room and an invite), else the reason in words."""
        if self.store.by_email(email): return None
        if self.invite_only and not self.store.invited(email): return "Dex Notch is in a closed beta and this address isn't on the list yet."
        if self.max_users and self.store.user_count() >= self.max_users: return "The beta is full right now."
        return None

    def _gc(self, c) -> None:
        for t in ("grants", "login_links", "sessions"): c.execute("DELETE FROM %s WHERE exp<=?" % t, (self.now(),))

    # -- OAuth clients (dynamic registration)
    def register(self, redirect_uris: List[str], name: str) -> str:
        if not redirect_uris or not isinstance(redirect_uris, list): raise AuthError("redirect_uris required")
        for u in redirect_uris:
            if not (is_loopback(u) or https_redirect_ok(u, self.allowed)): raise AuthError("redirect_uri not allowed: %s" % u)
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
        if len(email) > 254 or not EMAIL.fullmatch(email): raise AuthError("invalid email")  # also keeps newlines out of mail headers
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
        uid = self.store.by_email(r["email"])
        if not uid:
            if self.may_join(r["email"]): raise AuthError("this address can't create an account right now")  # re-checked: an invite may have been withdrawn, or the beta filled, since the mail went out
            uid = self.store.create_user(r["email"])
            if self.on_new_user: self.on_new_user(r["email"])
        return self.new_session(uid), uid, r["next"]

    def new_session(self, uid: str, key: bytes = None) -> str:
        """A browser session. `key`: the account's data key when a passkey just opened the vault; it is kept only wrapped under this session's cookie, like a device's."""
        sess = secrets.token_urlsafe(32)
        with self.store.conn() as c:
            c.execute("INSERT INTO sessions(hash,user_id,exp,wrapped) VALUES(?,?,?,?)", (_h(sess), uid, self.now() + (UNLOCKED_TTL if key else SESSION_TTL), seal.wrap(_kek(sess), key) if key else None))
        return sess

    def unlock_session(self, sess: str, key: bytes) -> None:
        with self.store.conn() as c: c.execute("UPDATE sessions SET wrapped=?, exp=MIN(exp, ?) WHERE hash=?", (seal.wrap(_kek(sess), key), self.now() + UNLOCKED_TTL, _h(sess or "")))

    def session_key(self, sess: str) -> Optional[bytes]:
        with self.store.conn() as c: r = c.execute("SELECT wrapped, exp FROM sessions WHERE hash=?", (_h(sess or ""),)).fetchone()
        return seal.unwrap(_kek(sess), r["wrapped"]) if r and r["wrapped"] and r["exp"] > self.now() else None

    def session_user(self, sess: str) -> Optional[str]:
        with self.store.conn() as c: r = c.execute("SELECT user_id, exp FROM sessions WHERE hash=?", (_h(sess or ""),)).fetchone()
        return r["user_id"] if r and r["exp"] > self.now() and self.store.status(r["user_id"]) not in (None, "deleted") else None

    def connected(self, uid: str) -> bool:
        """True while some assistant (Claude, ChatGPT) holds a live authorization for this user."""
        with self.store.conn() as c:
            return bool(c.execute("SELECT 1 FROM grants WHERE user_id=? AND kind='refresh' AND exp>? LIMIT 1", (uid, self.now())).fetchone())

    def assistants(self, uid: str) -> dict:
        """Which assistants hold a live authorization: {"claude", "chatgpt", "codex"}. From the name each one registered under; shown to the person and to their Mac, nothing more.
        An authorization made before the vault was locked is not counted: it can no longer open anything, so saying "connected" would be wrong."""
        with self.store.conn() as c:
            locked = bool(c.execute("SELECT 1 FROM vault_keys WHERE user_id=?", (uid,)).fetchone())
            names = [r["name"].lower() for r in c.execute("SELECT DISTINCT c.name FROM grants g JOIN clients c ON c.id=g.client_id WHERE g.user_id=? AND g.kind='refresh' AND g.exp>?" + (" AND g.wrapped IS NOT NULL" if locked else ""), (uid, self.now()))]
        return {"claude": any("claude" in n for n in names), "chatgpt": any("chatgpt" in n or "openai" in n for n in names), "codex": any("codex" in n for n in names)}

    def end_session(self, sess: str) -> None:
        with self.store.conn() as c: c.execute("DELETE FROM sessions WHERE hash=?", (_h(sess or ""),))

    def revoke_all(self, uid: str) -> None:
        """Sign out everywhere: browser sessions and every OAuth grant (so ChatGPT/Claude must re-authorize)."""
        with self.store.conn() as c:
            c.execute("DELETE FROM sessions WHERE user_id=?", (uid,)); c.execute("DELETE FROM grants WHERE user_id=?", (uid,))

    # -- OAuth grants
    def issue_code(self, cid: str, uid: str, redirect_uri: str, challenge: str, key: bytes = None) -> str:
        if not redirect_ok(self.client(cid)["redirect_uris"], redirect_uri): raise AuthError("redirect_uri mismatch")
        if not challenge: raise AuthError("code_challenge required")
        code = secrets.token_urlsafe(32)
        with self.store.conn() as c:
            self._gc(c)
            c.execute("INSERT INTO grants(hash,kind,user_id,client_id,data,exp,wrapped) VALUES(?,?,?,?,?,?,?)",
                      (_h(code), "code", uid, cid, json.dumps({"redir": redirect_uri, "ch": challenge}), self.now() + CODE_TTL, seal.wrap(_kek(code), key) if key else None))
        return code

    def _tokens(self, c, uid: str, cid: str, key: bytes = None) -> dict:
        """`key`: the account's data key. It is kept only wrapped under each new token, so a grant can open the vault only while its holder presents the token."""
        a, r, t = secrets.token_urlsafe(32), secrets.token_urlsafe(32), self.now()
        for tok, kind, ttl in ((a, "access", ACCESS_TTL), (r, "refresh", REFRESH_TTL)):
            c.execute("INSERT INTO grants(hash,kind,user_id,client_id,data,exp,wrapped) VALUES(?,?,?,?,NULL,?,?)", (_h(tok), kind, uid, cid, t + ttl, seal.wrap(_kek(tok), key) if key else None))
        return {"access_token": a, "token_type": "Bearer", "expires_in": ACCESS_TTL, "refresh_token": r}

    def exchange(self, code: str, cid: str, redirect_uri: str, verifier: str) -> dict:
        with self.store.conn() as c:  # the pop commits even when a check below fails: a code is single use no matter what
            rec = _pop(c, "grants", _h(code or ""), "code")
        if not rec or rec["exp"] <= self.now(): raise AuthError("invalid or expired code")
        d = json.loads(rec["data"])
        if rec["client_id"] != cid or d["redir"] != redirect_uri: raise AuthError("code does not match client")
        want = base64.urlsafe_b64encode(hashlib.sha256((verifier or "").encode()).digest()).rstrip(b"=").decode()
        if not hmac.compare_digest(want, d["ch"]): raise AuthError("PKCE verification failed")
        key = seal.unwrap(_kek(code), rec["wrapped"]) if rec["wrapped"] else None
        with self.store.conn() as c: return self._tokens(c, rec["user_id"], cid, key)

    def refresh(self, refresh_token: str, cid: str) -> dict:
        with self.store.conn() as c: rec = _pop(c, "grants", _h(refresh_token or ""), "refresh")
        if not rec or rec["exp"] <= self.now() or rec["client_id"] != cid: raise AuthError("invalid refresh token")
        key = seal.unwrap(_kek(refresh_token), rec["wrapped"]) if rec["wrapped"] else None
        with self.store.conn() as c: return self._tokens(c, rec["user_id"], cid, key)

    def check(self, access_token: str) -> Optional[str]:
        """The user id behind a valid access token, else None. Entitlement is a separate check (Store.entitled)."""
        with self.store.conn() as c:
            r = c.execute("SELECT user_id, exp, wrapped FROM grants WHERE hash=? AND kind='access'", (_h(access_token or ""),)).fetchone()
            if r and r["wrapped"] is None and c.execute("SELECT 1 FROM vault_keys WHERE user_id=?", (r["user_id"],)).fetchone(): return None   # connected before the vault was encrypted: connect again
        return r["user_id"] if r and r["exp"] > self.now() else None

    def key(self, access_token: str) -> Optional[bytes]:
        """The account's data key, unwrapped with this access token for one request. None for an account that is not encrypted."""
        with self.store.conn() as c: r = c.execute("SELECT wrapped FROM grants WHERE hash=? AND kind='access'", (_h(access_token or ""),)).fetchone()
        return seal.unwrap(_kek(access_token), r["wrapped"]) if r and r["wrapped"] else None
