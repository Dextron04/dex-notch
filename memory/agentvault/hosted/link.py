"""Linking a Mac to an account without pasting a token: the app starts a link, the person approves it in the browser (signed in by email link), the app collects its device token.
Like a TV sign-in: the code on screen goes to the browser, the secret never leaves the app. The code can only be approved by a signed-in user; the secret can only collect the token, once."""
import hashlib, secrets, time
from typing import Optional, Tuple
from . import devices
from .store import Store

TTL = 600
ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O/1/I/L: read aloud or off a screen without mistakes

class LinkError(Exception): pass

def _h(s: str) -> str: return hashlib.sha256(s.encode()).hexdigest()
def normalize(code: str) -> str: return "".join(ch for ch in (code or "").upper() if ch in ALPHABET)[:8]
def pretty(code: str) -> str: return code[:4] + "-" + code[4:]

def _gc(c, now: float) -> None: c.execute("DELETE FROM links WHERE exp<=?", (now,))

def start(store: Store, name: str, now: float = None) -> Tuple[str, str]:
    """(code, secret). The code is for the person to see, the secret for the app to keep."""
    now = now or time.time()
    name = " ".join((name or "").split())[:60] or "My Mac"
    code, secret = "".join(secrets.choice(ALPHABET) for _ in range(8)), secrets.token_urlsafe(32)
    with store.conn() as c:
        _gc(c, now)
        if c.execute("SELECT COUNT(*) FROM links").fetchone()[0] >= 5000: raise LinkError("busy, try again in a few minutes")
        c.execute("INSERT INTO links(code,secret_hash,name,exp) VALUES(?,?,?,?)", (code, _h(secret), name, now + TTL))
    return code, secret

def peek(store: Store, code: str, now: float = None) -> Optional[str]:
    """The Mac's name while the link is open and unapproved, else None."""
    with store.conn() as c: r = c.execute("SELECT name FROM links WHERE code=? AND exp>? AND user_id IS NULL", (normalize(code), now or time.time())).fetchone()
    return r["name"] if r else None

def approve(store: Store, code: str, uid: str, now: float = None) -> str:
    """Creates the device and parks its token for the app to collect. Returns the Mac's name."""
    now = now or time.time()
    with store.conn() as c:
        r = c.execute("SELECT name FROM links WHERE code=? AND exp>? AND user_id IS NULL", (normalize(code), now)).fetchone()
        if not r: raise LinkError("this link has expired or was already used")
    try: _, tok = devices.create(store, uid, r["name"], now)
    except ValueError as e: raise LinkError(str(e))
    with store.conn() as c:
        if not c.execute("UPDATE links SET user_id=?, token=?, exp=? WHERE code=? AND user_id IS NULL", (uid, tok, now + 120, normalize(code))).rowcount:
            raise LinkError("this link has expired or was already used")   # lost a race with another approval
    return r["name"]

def poll(store: Store, secret: str, now: float = None) -> Tuple[str, Optional[str], Optional[str]]:
    """("pending"|"approved"|"expired", device token, user id). The token is handed over once and erased."""
    now = now or time.time()
    with store.conn() as c:
        r = c.execute("SELECT code, user_id, token, exp FROM links WHERE secret_hash=?", (_h(secret or ""),)).fetchone()
        if not r or r["exp"] <= now: return "expired", None, None
        if not r["user_id"]: return "pending", None, None
        c.execute("DELETE FROM links WHERE code=?", (r["code"],))
        return "approved", r["token"], r["user_id"]
