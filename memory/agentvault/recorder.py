"""Poll-and-append engine. State (byte offsets per source file) is saved after EVERY file,
so a killed backfill resumes where it stopped and never double-writes a note."""
import hashlib, json, os
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional
from .adapters.base import Adapter
from .index import rebuild_indexes
from .model import SessionMeta
from .notes import append_turns, reset_note, write_atomic

def _merge(old: Optional[dict], new: Optional[SessionMeta]) -> Optional[dict]:
    n = asdict(new) if new else None
    if not old or not n: return n or old
    out = dict(old)
    for k, v in n.items():
        if k in ("agent", "session_id", "started", "source_path", "project", "cwd"): out[k] = out.get(k) or v
        elif v: out[k] = v
    return out

def _key(t) -> str:
    return hashlib.sha1(("%s|%s|%s" % (t.role, t.ts, t.text)).encode("utf-8", "replace")).hexdigest()[:10]

def _load(path: Path) -> dict:
    try: return json.loads(path.read_text())
    except (OSError, ValueError): return {}

def tick(vault: Path, adapters: List[Adapter], state_path: Optional[Path] = None) -> Dict:
    vault = Path(vault)
    rec = vault / ".recorder"
    state_path = Path(state_path) if state_path else rec / "state.json"
    state = _load(state_path)
    sessions = state.setdefault("_sessions", {})  # session_id -> {project,cwd,started,seen[]}: identity + dedupe across file copies
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
                        reset_note(vault, SessionMeta(**st["meta"])); sessions.pop(st["meta"]["session_id"], None)
                    st = None
                if st and size == st["offset"]: continue
                stats["files"] += 1
                meta, turns, off = ad.parse(path, st["offset"] if st else 0)
                merged = _merge(st["meta"] if st else None, meta)
                if merged and not merged.get("started") and turns: merged["started"] = turns[0].ts
                if merged:  # the same session id can live in several files (resumed copies): one identity, no repeats
                    ident = sessions.setdefault(merged["session_id"], {"project": merged["project"], "cwd": merged["cwd"],
                                                                      "started": merged["started"], "seen": []})
                    merged.update({k: ident[k] for k in ("project", "cwd", "started")})
                    seen = set(ident["seen"])
                    fresh = [t for t in turns if _key(t) not in seen]
                    ident["seen"].extend(_key(t) for t in fresh)
                    turns = fresh
                if merged and (turns or (st and meta and merged != st["meta"])):
                    append_turns(vault, SessionMeta(**merged), turns)
                stats["new_turns"] += len(turns)
                state[key] = {"offset": off, "size": size, "meta": merged,
                              "turns": (st["turns"] if st else 0) + len(turns)}
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
    return tick(vault, adapters)
