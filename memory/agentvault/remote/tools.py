"""The one write tool the remote connector adds: `remember`. Notes go through the same redacting, idempotent writer as the recorder."""
import hashlib, json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from ..model import SessionMeta, Turn
from ..notes import add_turns, write_atomic
from ..redact import redact

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


REMIND = {"name": "remind", "title": "Remind me at a time (shows at the Dex Notch)",
    "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False},
    "description": "Set a reminder that pops up at the notch of the user's Mac at the given time (shown when they next use the Mac if it was asleep). "
                   "Use when the user asks to be reminded of something. `when` MUST be a full ISO-8601 time WITH the user's UTC offset, e.g. "
                   "2026-11-16T09:00:00-06:00; work it out from the user's local date and time, and ask them if you don't know their timezone. "
                   "`text` is what the reminder says: short and self-contained. Never include passwords or API keys.",
    "inputSchema": {"type": "object", "required": ["text", "when", "source"], "properties": {
        "text": {"type": "string", "description": "what to remind the user of (max 500 characters)"},
        "when": {"type": "string", "description": "ISO-8601 date-time with UTC offset, e.g. 2026-11-16T09:00:00-06:00"},
        "source": {"type": "string", "enum": sorted(SOURCES), "description": "which assistant you are: chatgpt | claude | other"}}}}

def remind(vault: Path, a: dict, now=None) -> str:
    text, when, source = " ".join(str(a.get("text", "")).split()), str(a.get("when", "")).strip(), a.get("source")
    if source not in SOURCES: raise ValueError("source must be one of: %s" % ", ".join(sorted(SOURCES)))
    if not text: raise ValueError("text is required")
    if len(text) > 500: raise ValueError("text too long (%d > 500 characters); make it shorter" % len(text))
    try: due = datetime.fromisoformat(when)
    except ValueError: raise ValueError("when must be an ISO-8601 time like 2026-11-16T09:00:00-06:00")
    if due.tzinfo is None: raise ValueError("when needs the user's UTC offset, e.g. 2026-11-16T09:00:00-06:00; ask the user for their timezone if unsure")
    now = now or datetime.now(timezone.utc)
    due = due.astimezone(timezone.utc)
    if due < now - timedelta(days=1): raise ValueError("that time is in the past; check the date and the year")
    if due > now + timedelta(days=730): raise ValueError("that is more than two years away; pick a nearer date")
    due_s = due.strftime("%Y-%m-%dT%H:%M:%SZ")
    rid = hashlib.sha1((text + "\n" + due_s).encode("utf-8", "replace")).hexdigest()[:16]  # same reminder twice = same file
    fm = "".join("%s: %s\n" % (k, json.dumps(v, ensure_ascii=False)) for k, v in
                 (("id", rid), ("due", due_s), ("text", redact(text)), ("source", SOURCES[source]), ("created", now.strftime("%Y-%m-%dT%H:%M:%SZ"))))
    write_atomic(Path(vault) / "Reminders" / ("%s.md" % rid), "---\n" + fm + "---\n")
    return "Reminder set for %s UTC. It will show at the user's notch." % due.strftime("%Y-%m-%d %H:%M")
