"""The Mac's side of the hosted service: upload new turns from the local vault to /v1/ingest.
Reads the notes the recorder already wrote (so history and live sessions take the same path) and remembers how many turns of each it has sent."""
import json, urllib.error, urllib.request
from pathlib import Path
from typing import Callable, Optional
from .index import session_files
from .notes import read_note, write_atomic

MAX_REQUEST, MAX_SESSIONS, CHUNK_TURNS = 2_000_000, 100, 1500  # well under the server's 8 MB / 100 sessions / 5000 turns

class HostedError(Exception):
    """The service said no in a way retrying won't fix (revoked token, no subscription, quota)."""

def _post(base: str, token: str, payload: dict) -> dict:
    req = urllib.request.Request(base.rstrip("/") + "/v1/ingest", data=json.dumps(payload).encode(), method="POST", headers={
        "Authorization": "Bearer " + token, "Content-Type": "application/json", "User-Agent": "agentvault-hosted/1"})  # Cloudflare turns away the default Python-urllib agent
    try:
        with urllib.request.urlopen(req, timeout=60) as r: return json.load(r)
    except urllib.error.HTTPError as e:
        msg = {401: "device token rejected (removed from your account?)", 402: "no active subscription", 413: "storage quota reached"}.get(e.code)
        e.close()
        if msg: raise HostedError(msg)
        raise

def push(vault: Path, base: str, token: str, post: Callable[[str, str, dict], dict] = _post, state_path: Optional[Path] = None) -> dict:
    """Uploads whatever is new. Safe to rerun at any point: the server dedupes, and state only advances after a request succeeds."""
    vault = Path(vault); sp = Path(state_path) if state_path else vault / ".recorder" / "hosted_state.json"
    try: state = json.loads(sp.read_text())
    except (OSError, ValueError): state = {}
    stats, batch, size = {"sessions": 0, "turns": 0}, [], 0

    def flush() -> None:
        nonlocal batch, size
        if not batch: return
        post(base, token, {"sessions": [b["item"] for b in batch]})
        for b in batch: state[b["rel"]] = b["after"]
        stats["sessions"] += len(batch); stats["turns"] += sum(len(b["item"]["turns"]) for b in batch)
        write_atomic(sp, json.dumps(state)); batch, size = [], 0

    for p in session_files(vault):
        rel, st = p.relative_to(vault).as_posix(), p.stat()
        prev = state.get(rel) or {}
        if (prev.get("mt"), prev.get("size")) == (st.st_mtime_ns, st.st_size): continue
        meta, turns = read_note(p)
        sent = min(int(prev.get("sent", 0)), len(turns))
        new = turns[sent:]
        if not new and prev and meta.get("title", "") == prev.get("title", ""): state[rel] = dict(prev, mt=st.st_mtime_ns, size=st.st_size); continue   # a late title is still worth sending
        m = {k: meta.get(k, "") for k in ("agent", "session_id", "project", "cwd", "started", "title")}
        for i in range(0, max(len(new), 1), CHUNK_TURNS):
            chunk = new[i:i + CHUNK_TURNS]
            item = {"meta": m, "turns": [{"role": t.role, "text": t.text, "ts": t.ts} for t in chunk]}
            n = len(json.dumps(item))
            if batch and (size + n > MAX_REQUEST or len(batch) >= MAX_SESSIONS): flush()
            last = i + CHUNK_TURNS >= len(new)
            batch.append({"rel": rel, "item": item, "after": {"sent": sent + i + len(chunk), "title": m["title"], **({"mt": st.st_mtime_ns, "size": st.st_size} if last else {})}}); size += n
    flush()
    return stats
