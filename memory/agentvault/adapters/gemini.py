"""Gemini / Antigravity: ~/.gemini/antigravity-ide/brain/<conv>/.system_generated/logs/transcript.jsonl
(step records: source USER_EXPLICIT/MODEL/SYSTEM, type USER_INPUT/PLANNER_RESPONSE/RUN_COMMAND/...).
Kept: <USER_REQUEST> text, PLANNER_RESPONSE content, other MODEL steps as `ran: <TYPE>`.
Dropped: `thinking`, tool output bodies, SYSTEM steps. The protobuf conversation DB under
~/.gemini/antigravity/ is not read. Project is inferred from the 'Active Document' path."""
import re
from pathlib import Path
from typing import Iterator
from .base import Adapter, iter_json_lines, flat
from ..model import Turn, SessionMeta

_REQ = re.compile(r"<USER_REQUEST>\s*([\s\S]*?)\s*</USER_REQUEST>")
_DOC = re.compile(r"Active Document: (/\S+)")
_SKIP = {"GENERIC", "ASK_QUESTION"}

class GeminiAdapter(Adapter):
    name = "gemini"
    def default_root(self) -> Path: return Path("~/.gemini/antigravity-ide/brain").expanduser()
    def discover(self) -> Iterator[Path]:
        yield from sorted(self.root.glob("*/.system_generated/logs/transcript.jsonl"))

    def parse(self, path, offset):
        turns, off, cwd, started, seen = [], offset, "", "", False
        for d, end in iter_json_lines(path, offset):
            off = end
            if not d: continue
            seen = True
            ts, typ, src = d.get("created_at", ""), d.get("type", ""), d.get("source", "")
            started = started or ts
            c = d.get("content") or ""
            if src == "USER_EXPLICIT" and typ == "USER_INPUT":
                m = _REQ.search(c)
                if (m.group(1) if m else c).strip(): turns.append(Turn("user", (m.group(1) if m else c).strip(), ts))
                doc = _DOC.search(c)
                if doc and not cwd:
                    parts = doc.group(1).split("/")
                    if len(parts) > 4: cwd = "/".join(parts[:4])
            elif src == "MODEL" and typ == "PLANNER_RESPONSE":
                if c.strip(): turns.append(Turn("assistant", c.strip(), ts))
            elif src == "MODEL" and typ not in _SKIP:
                turns.append(Turn("tool", "ran: %s" % typ, ts))
        if not seen: return None, [], off
        project = cwd.rsplit("/", 1)[-1] if cwd else "antigravity"
        title = next((flat(t.text, 60) for t in turns if t.role == "user"), "") if offset == 0 else ""
        return SessionMeta("gemini", path.parents[2].name, project, cwd, started, title, str(path)), turns, off
