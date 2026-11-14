"""Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. Kept: real user text (injected AGENTS.md /
environment context stripped), assistant `final_answer` messages, function calls as one-liners.
Dropped: developer messages, reasoning, commentary, call outputs, events."""
import json, os
from pathlib import Path
from typing import Iterator
from .base import Adapter, iter_json_lines, flat, tool_line
from ..model import Turn, SessionMeta

_INJECTED = ("# AGENTS.md", "<environment_context", "<user_instructions", "<permissions", "<collaboration_mode", "<INSTRUCTIONS",
             "<heartbeat", "<external_codex_apps", "Host notice", ">>> ", "The active permission", "Assess the exact", "Planned action JSON", "The following is the Codex agent history")

def _texts(content, kind):
    return [b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == kind]

class CodexAdapter(Adapter):
    name = "codex"
    def default_root(self) -> Path: return Path("~/.codex/sessions").expanduser()
    def discover(self) -> Iterator[Path]:
        yield from sorted(self.root.glob("*/*/*/rollout-*.jsonl"))

    def parse(self, path, offset):
        turns, off, cwd, started, seen = [], offset, "", "", False
        for d, end in iter_json_lines(path, offset):
            off = end
            if not d: continue
            seen = True
            ts, p = d.get("timestamp", ""), d.get("payload") or {}
            started = started or ts
            if d.get("type") == "session_meta":
                cwd, started = p.get("cwd", cwd), p.get("timestamp") or started
                continue
            if d.get("type") != "response_item": continue
            pt = p.get("type")
            if pt == "message" and p.get("role") == "user":
                for s in _texts(p.get("content"), "input_text"):
                    if s.strip() and not s.lstrip().startswith(_INJECTED + ("{",)): turns.append(Turn("user", s.strip(), ts))
            elif pt == "message" and p.get("role") == "assistant" and p.get("phase") == "final_answer":
                s = "\n".join(_texts(p.get("content"), "output_text")).strip()
                if s: turns.append(Turn("assistant", s, ts))
            elif pt in ("function_call", "custom_tool_call", "local_shell_call"):
                raw = p.get("arguments", p.get("input", ""))
                try: raw = json.loads(raw)
                except (ValueError, TypeError): pass
                turns.append(Turn("tool", tool_line(p.get("name", pt), raw), ts))
        if not seen: return None, [], off
        title = next((flat(t.text, 60) for t in turns if t.role == "user"), "") if offset == 0 else ""
        return SessionMeta("codex", path.stem, os.path.basename(cwd), cwd, started, title, str(path)), turns, off
