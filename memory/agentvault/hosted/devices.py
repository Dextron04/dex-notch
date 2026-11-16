"""Device tokens: the credential a Mac's recorder uses to upload notes and wait for reminders. One per Mac, revocable, stored hashed.
Separate from OAuth tokens on purpose: those belong to ChatGPT/Claude, these to the user's own machine, and neither can do the other's job."""
import hashlib, secrets, time
from typing import List, Optional, Tuple
from .store import Store

MAX_DEVICES = 10
PREFIX = "dvt_"

def _h(t: str) -> str: return hashlib.sha256(t.encode()).hexdigest()

def create(store: Store, uid: str, name: str, now: float = None) -> Tuple[str, str]:
    """Returns (device id, token). The token is shown once and never recoverable."""
    name = " ".join((name or "").split())[:60] or "My Mac"
    with store.conn() as c:
        if c.execute("SELECT COUNT(*) FROM devices WHERE user_id=? AND revoked=0", (uid,)).fetchone()[0] >= MAX_DEVICES: raise ValueError("device limit reached; remove one first")
        did, tok = "d_" + secrets.token_urlsafe(9), PREFIX + secrets.token_urlsafe(32)
        c.execute("INSERT INTO devices(id,user_id,name,token_hash,created_at) VALUES(?,?,?,?,?)", (did, uid, name, _h(tok), now or time.time()))
    return did, tok

def check(store: Store, token: str, now: float = None) -> Optional[Tuple[str, str]]:
    """(user id, device id) for a live token, else None. Touches last_seen at most once a minute."""
    if not (token or "").startswith(PREFIX): return None
    now = now or time.time()
    with store.conn() as c:
        r = c.execute("SELECT id, user_id, last_seen FROM devices WHERE token_hash=? AND revoked=0", (_h(token),)).fetchone()
        if not r: return None
        if not r["last_seen"] or now - r["last_seen"] > 60: c.execute("UPDATE devices SET last_seen=? WHERE id=?", (now, r["id"]))
    return r["user_id"], r["id"]

def listing(store: Store, uid: str) -> List[dict]:
    with store.conn() as c:
        return [dict(r) for r in c.execute("SELECT id,name,created_at,last_seen FROM devices WHERE user_id=? AND revoked=0 ORDER BY created_at", (uid,))]

def revoke(store: Store, uid: str, did: str) -> bool:
    with store.conn() as c: return bool(c.execute("UPDATE devices SET revoked=1 WHERE id=? AND user_id=?", (did, uid)).rowcount)  # user_id in the WHERE: you can only revoke your own
