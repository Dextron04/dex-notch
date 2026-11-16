"""One-shot imports of chat-app data exports into the vault. Idempotent: notes dedupe turns by hash, so rerunning is safe."""
import fcntl, json, tempfile, zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterator, List, Optional
from .index import rebuild_indexes
from .model import SessionMeta, Turn
from .notes import add_turns

def _iso(t) -> str:
    return datetime.fromtimestamp(float(t or 0), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def _text(content: dict) -> str:
    """Visible text only. Thoughts and recaps are the model's scratchpad; images/files become a marker."""
    if content.get("content_type") not in ("text", "multimodal_text"): return ""
    out = []
    for p in content.get("parts") or []:
        if isinstance(p, str): out.append(p)
        elif isinstance(p, dict) and p.get("content_type", "").startswith("image"): out.append("[image]")
        elif isinstance(p, dict) and p.get("text"): out.append(str(p["text"]))
    return "\n\n".join(s for s in out if s.strip()).strip()

def chatgpt_turns(conv: dict) -> List[Turn]:
    """The branch the user ended on: current_node walked back to the root, then reversed."""
    m, chain, node, seen = conv.get("mapping") or {}, [], conv.get("current_node"), set()
    while node and node in m and node not in seen:
        seen.add(node); chain.append(m[node]); node = m[node].get("parent")
    turns = []
    for n in reversed(chain):
        msg = n.get("message") or {}
        role = (msg.get("author") or {}).get("role")
        if role not in ("user", "assistant") or (msg.get("metadata") or {}).get("is_visually_hidden_from_conversation"): continue
        txt = _text(msg.get("content") or {})
        if txt: turns.append(Turn(role, txt, _iso(msg.get("create_time") or conv.get("create_time"))))
    return turns

def _conversations(src: Path) -> Iterator[dict]:
    files = [src] if src.is_file() else sorted(src.glob("conversations*.json"))
    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        yield from (d if isinstance(d, list) else [d])

def import_chatgpt(vault: Path, src: Path) -> Dict:
    """src: the unzipped export folder, the export .zip, or a single conversations*.json."""
    src, vault = Path(src).expanduser(), Path(vault).expanduser()
    if not src.exists(): raise FileNotFoundError(src)
    if src.suffix == ".zip":
        with tempfile.TemporaryDirectory() as tmp, zipfile.ZipFile(src) as z:
            for n in z.namelist():
                if Path(n).name.startswith("conversations") and n.endswith(".json"): z.extract(n, tmp)
            return import_chatgpt(vault, next((p for p in [Path(tmp)] + list(Path(tmp).iterdir()) if any(p.glob("conversations*.json"))), Path(tmp)))
    (vault / ".recorder").mkdir(parents=True, exist_ok=True)
    stats = {"chats": 0, "empty": 0, "new_turns": 0, "errors": []}
    with open(vault / ".recorder" / "lock", "w") as lock:  # never race the recorder daemon
        fcntl.flock(lock, fcntl.LOCK_EX)
        for c in _conversations(src):
            try:
                turns = chatgpt_turns(c)
                if not turns: stats["empty"] += 1; continue
                meta = SessionMeta("chatgpt", str(c.get("conversation_id") or c["id"]), "chats", "", turns[0].ts,
                                   c.get("title") or "", "chatgpt-export")
                stats["new_turns"] += add_turns(vault, meta, turns)[1]; stats["chats"] += 1
            except Exception as e: stats["errors"].append("%s: %s" % (c.get("id"), e))
        rebuild_indexes(vault)
    return stats

def find_chatgpt_export() -> Optional[Path]:
    """Newest export the user left in Downloads (folder or zip), so `import chatgpt` works with no path."""
    d = Path("~/Downloads").expanduser()
    c = [p for p in list(d.glob("chatgpt*")) + list(d.glob("*chatgpt*.zip")) if p.is_dir() or p.suffix == ".zip"]
    return max(c, key=lambda p: p.stat().st_mtime, default=None)
