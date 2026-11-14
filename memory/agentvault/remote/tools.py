"""The one write tool the remote connector adds: `remember`. Notes go through the same redacting, idempotent writer as the recorder."""
import hashlib
from datetime import datetime, timezone
from pathlib import Path
from ..model import SessionMeta, Turn
from ..notes import add_turns

MAX_CHARS = 200_000
SOURCES = {"chatgpt": "chatgpt", "claude": "claude-web", "other": "other-ai"}

REMEMBER = {"name": "remember", "title": "Save this conversation to memory",
    # adds a note, never edits or deletes one; saving the same thing twice gives the same note; touches only the user's own vault
    "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False},
    "description": "Save context from the CURRENT conversation into the user's shared long-term memory (Obsidian vault), so their other AI agents "
                   "can find it later. Use when the user asks to save/push/remember this chat. Put the substance in `content`: decisions, facts, "
                   "code, open questions, in as much detail as is useful (full text if short). Never include passwords or API keys.",
    "inputSchema": {"type": "object", "required": ["title", "content", "source"], "properties": {
        "title": {"type": "string", "description": "short title of the conversation"},
        "content": {"type": "string", "description": "the context to save (markdown)"},
        "source": {"type": "string", "enum": sorted(SOURCES), "description": "which assistant you are: chatgpt | claude | other"}}}}

def remember(vault: Path, a: dict) -> str:
    title, content, source = str(a.get("title", "")).strip(), str(a.get("content", "")).strip(), a.get("source")
    if source not in SOURCES: raise ValueError("source must be one of: %s" % ", ".join(sorted(SOURCES)))
    if not title or not content: raise ValueError("title and content are required")
    if len(content) > MAX_CHARS: raise ValueError("content too long (%d > %d characters); split it into several saves" % (len(content), MAX_CHARS))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sid = hashlib.sha1((title + "\n" + content).encode("utf-8", "replace")).hexdigest()[:16]  # same save twice = same note
    meta = SessionMeta(SOURCES[source], sid, "chats", "", now, title, "remote:remember")
    path, _ = add_turns(Path(vault), meta, [Turn("assistant", content, now)])
    return "Saved to %s" % path.relative_to(vault).as_posix()
