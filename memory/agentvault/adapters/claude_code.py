"""Claude Code: ~/.claude/projects/<project>/<session>.jsonl (one JSON record per line).
Kept: human user prompts, assistant text, tool_use as one-liners. Dropped: thinking, tool_result,
isMeta/sidechain records (skill injections, subagents), and every internal bookkeeping record type."""
import os, re
from pathlib import Path
from typing import Iterator
from .base import Adapter, iter_json_lines, flat, tool_line
from ..model import Turn, SessionMeta

_REMINDER = re.compile(r"<system-reminder>[\s\S]*?</system-reminder>")

def _user_text(d: dict) -> str:
    o = d.get("origin")
    if isinstance(o, dict) and o.get("kind") not in (None, "human"): return ""
    c = (d.get("message") or {}).get("content")
    if isinstance(c, list): c = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return _REMINDER.sub("", c).strip() if isinstance(c, str) else ""

class ClaudeCodeAdapter(Adapter):
    name = "claude-code"
    def default_root(self) -> Path: return Path("~/.claude/projects").expanduser()
    def discover(self) -> Iterator[Path]:
        yield from sorted(self.root.glob("*/*.jsonl"), key=lambda p: p.stat().st_mtime)

    def parse(self, path, offset):
        turns, off, cwd, started, title, seen = [], offset, "", "", "", False
        for d, end in iter_json_lines(path, offset):
            off = end
            if not d: continue
            seen = True
            ts = d.get("timestamp", "")
            started = started or ts
            cwd = cwd or d.get("cwd") or ""
            t = d.get("type")
            if t == "ai-title": title = d.get("aiTitle") or title; continue
            if d.get("isSidechain") or d.get("isMeta"): continue
            if t == "user":
                text = _user_text(d)
                if text: turns.append(Turn("user", text, ts))
            elif t == "assistant":
                c = (d.get("message") or {}).get("content")
                for b in c if isinstance(c, list) else []:
                    if not isinstance(b, dict): continue
                    if b.get("type") == "text" and b.get("text", "").strip(): turns.append(Turn("assistant", b["text"].strip(), ts))
                    elif b.get("type") == "tool_use": turns.append(Turn("tool", tool_line(b.get("name", "tool"), b.get("input")), ts))
        if not seen: return None, [], off
        if not title and offset == 0:
            title = next((flat(t.text, 60) for t in turns if t.role == "user"), "")
        return SessionMeta("claude-code", path.stem, os.path.basename(cwd), cwd, started, title, str(path)), turns, off
