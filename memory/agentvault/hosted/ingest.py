"""POST /v1/ingest: a Mac's recorder uploads sessions. The server never trusts the client's idea of a note: it validates the fields, redacts,
and builds the note itself with the same idempotent writer as everything else, so a repeated or overlapping upload changes nothing."""
import os, re, threading
from pathlib import Path
from typing import List
from ..model import SessionMeta, Turn
from .. import seal
from ..notes import add_turns
from .store import Store

AGENT = re.compile(r"[a-z0-9][a-z0-9-]{0,29}")
TS = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z")
MAX_BODY = 8 * 1024 * 1024
MAX_SESSIONS, MAX_TURNS, MAX_TEXT = 100, 5000, 200_000
ROLES = {"user", "assistant", "tool"}
_locks, _guard = {}, threading.Lock()

def user_lock(uid: str) -> threading.Lock:
    with _guard: return _locks.setdefault(uid, threading.Lock())

class IngestError(ValueError):
    pass

def vault_bytes(vault: Path) -> int:
    n = 0
    for root, _, files in os.walk(vault):
        for f in files:
            try: n += os.lstat(os.path.join(root, f)).st_size
            except OSError: pass
    return n

def _str(v, field, lo, hi, rx=None) -> str:
    if not isinstance(v, str) or not (lo <= len(v) <= hi) or (rx and not rx.fullmatch(v)): raise IngestError("bad %s" % field)
    return v

def parse(payload) -> List[tuple]:
    """Validates the whole request first (a bad one writes nothing). Returns [(SessionMeta, [Turn])]."""
    sessions = payload.get("sessions") if isinstance(payload, dict) else None
    if not isinstance(sessions, list) or not (1 <= len(sessions) <= MAX_SESSIONS): raise IngestError("sessions must be a list of 1-%d" % MAX_SESSIONS)
    out = []
    for s in sessions:
        m, t = (s.get("meta"), s.get("turns")) if isinstance(s, dict) else (None, None)
        if not isinstance(m, dict) or not isinstance(t, list) or len(t) > MAX_TURNS: raise IngestError("bad session")
        started = m.get("started") or ""
        if started: _str(started, "started", 20, 27, TS)
        meta = SessionMeta(_str(m.get("agent"), "agent", 1, 30, AGENT), _str(m.get("session_id"), "session_id", 1, 200), _str(m.get("project", ""), "project", 0, 200),
                           _str(m.get("cwd", ""), "cwd", 0, 500), started, _str(m.get("title", ""), "title", 0, 500), "hosted:ingest")
        turns = []
        for x in t:
            if not isinstance(x, dict) or x.get("role") not in ROLES: raise IngestError("bad turn")
            turns.append(Turn(x["role"], _str(x.get("text"), "text", 0, MAX_TEXT), _str(x.get("ts"), "ts", 20, 27, TS)))
        out.append((meta, turns))
    return out

def ingest(store: Store, uid: str, payload: dict, body_bytes: int = 0) -> dict:
    parsed = parse(payload)
    vault = store.user_vault(uid)
    limit = store.quota(uid)
    if limit is not None and vault_bytes(vault) + body_bytes > limit: raise IngestError("storage quota reached (%d MB)" % (limit >> 20))
    new = 0
    with user_lock(uid):  # two Macs uploading the same session must not interleave the read-modify-write of its note
        if store.encrypted(uid) and seal.current() is None: raise IngestError("this Mac must be linked again (the vault is now encrypted)")   # never write plain text into an encrypted vault
        for meta, turns in parsed: new += add_turns(vault, meta, turns)[1]
    return {"sessions": len(parsed), "new_turns": new}
