"""Poll-and-append engine. State (byte offsets per source file) is saved after EVERY file,
so a killed backfill resumes where it stopped and never double-writes a note."""
import fcntl, json, os
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional
from .adapters.base import Adapter
from .index import rebuild_indexes
from .model import SessionMeta
from .notes import add_turns, reset_note, write_atomic

def _merge(old: Optional[dict], new: Optional[SessionMeta]) -> Optional[dict]:
    n = asdict(new) if new else None
    if not old or not n: return n or old
    out = dict(old)
    for k, v in n.items():
        if k in ("agent", "session_id", "started", "source_path", "project", "cwd"): out[k] = out.get(k) or v
        elif v: out[k] = v
    return out

def is_notch_private(cwd: str) -> bool:
    """Sessions the notch launches run in its scratch folder or a throwaway DexNotch-run-* dir. Notch chats stay local unless
    the user saves one to the vault, so every adapter's sessions from there are dropped in one place (the notch journal has no cwd)."""
    c = (cwd or "").rstrip("/") + "/"
    return "/Library/Application Support/NotchApp/" in c or "/DexNotch-run-" in c

class StateError(Exception):
    pass

def _load(path: Path) -> dict:
    """Missing state = first run. Unreadable state is NOT treated as empty: refuse, so nothing is re-recorded blindly."""
    if not path.exists(): return {}
    try:
        d = json.loads(path.read_text())
        if isinstance(d, dict): return d
    except (OSError, ValueError): pass
    raise StateError("%s is unreadable; fix or delete it (the vault dedupes, so a rebuild is safe)" % path)

def tick(vault: Path, adapters: List[Adapter], state_path: Optional[Path] = None, wait: bool = False) -> Dict:
    """One pass. Only one recorder may run per vault: a second one skips (or waits, when wait=True)."""
    vault = Path(vault)
    rec = vault / ".recorder"
    rec.mkdir(parents=True, exist_ok=True)
    with open(rec / "lock", "w") as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except OSError: return {"new_turns": 0, "files": 0, "errors": [], "skipped": True}
        return _tick(vault, adapters, state_path, rec)

def _tick(vault: Path, adapters: List[Adapter], state_path: Optional[Path], rec: Path) -> Dict:
    state_path = Path(state_path) if state_path else rec / "state.json"
    state = _load(state_path)
    sessions = state.setdefault("_sessions", {})  # session_id -> {project,cwd,started}: one note identity across file copies
    stats = {"new_turns": 0, "files": 0, "errors": []}
    states: Dict[str, str] = {}

    for ad in adapters:
        found = False
        try: files = list(ad.discover())
        except Exception as e:
            stats["errors"].append("%s: discover failed: %s" % (ad.name, e)); states[ad.name] = "error"; continue
        for path in files:
            found = True
            key = str(path)
            try:
                size = path.stat().st_size
                st = state.get(key)
                if st and size < st["offset"]:  # replaced/truncated: rebuild this note from scratch
                    if st.get("meta"):
                        sid = st["meta"]["session_id"]
                        reset_note(vault, SessionMeta(**st["meta"])); sessions.pop(sid, None)
                        for k2 in [k2 for k2, v2 in state.items() if k2 != "_sessions" and (v2.get("meta") or {}).get("session_id") == sid]:
                            del state[k2]  # every copy re-parses from 0; the note dedupes, so no repeats and no lost turns
                    st = None
                if st and size == st["offset"]: continue
                stats["files"] += 1
                meta, turns, off = ad.parse(path, st["offset"] if st else 0)
                merged = _merge(st["meta"] if st else None, meta)
                if merged and is_notch_private(merged.get("cwd", "")): turns = []  # consumed, never written
                added = 0
                if merged and turns:
                    # identity (project/cwd/started => note path) is fixed by the first chunk that has turns, never by header-only chunks
                    merged["started"] = merged.get("started") or turns[0].ts
                    ident = sessions.setdefault(merged["session_id"], {"project": merged["project"], "cwd": merged["cwd"], "started": merged["started"]})
                    merged.update(ident)
                    _, added = add_turns(vault, SessionMeta(**merged), turns)
                elif merged and st and meta and merged != st["meta"] and merged["session_id"] in sessions:
                    merged.update(sessions[merged["session_id"]])
                    add_turns(vault, SessionMeta(**merged), [])  # late title only
                stats["new_turns"] += added
                state[key] = {"offset": off, "size": size, "meta": merged,
                              "turns": (st["turns"] if st else 0) + added}
                rec.mkdir(parents=True, exist_ok=True)
                write_atomic(state_path, json.dumps(state))
            except Exception as e:  # one bad file never stops the rest
                stats["errors"].append("%s: %s" % (path.name, e)); states[ad.name] = "error"
        if ad.name not in states: states[ad.name] = "ok" if found else "unsupported"

    if stats["new_turns"] or not (vault / "Index.md").exists(): rebuild_indexes(vault)
    agents: Dict[str, dict] = {}
    for ad in adapters:
        mine = [s for k, s in state.items() if k != "_sessions" and s.get("meta") and s["meta"]["agent"] == ad.name and s.get("turns")]
        agents[ad.name] = {"sessions": len({s["meta"]["session_id"] for s in mine}), "turns": sum(s["turns"] for s in mine),
                           "state": states.get(ad.name, "ok")}
    write_atomic(rec / "status.json", json.dumps({
        "last_run": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "agents": agents, "errors": stats["errors"][-20:]}))
    return stats

def backfill(vault: Path, adapters: List[Adapter]) -> Dict:
    """First-run import of all history at low CPU priority. Safe to Ctrl-C and rerun."""
    try: os.nice(15)
    except OSError: pass
    return tick(vault, adapters, wait=True)
