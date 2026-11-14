"""The notch app's own Gemma chats: ~/Library/Application Support/NotchApp/journal/<conversation-id>.jsonl, one JSON object per
line {"v":1,"conv","role":"user|assistant","text","ts","model"}, appended by the app after each finished answer.
(Claude/Codex questions asked from the notch are recorded by those CLIs' own logs, so only Gemma needs a journal.)"""
import os
from pathlib import Path
from typing import Iterator
from .base import Adapter, iter_json_lines, flat
from ..model import Turn, SessionMeta

class NotchAdapter(Adapter):
    name = "gemma"
    def default_root(self) -> Path: return Path("~/Library/Application Support/NotchApp").expanduser()
    def discover(self) -> Iterator[Path]:
        yield from sorted((self.root / "journal").glob("*.jsonl"))

    def parse(self, path, offset):
        turns, off, seen = [], offset, False
        for d, end in iter_json_lines(path, offset):
            off = end
            if not d: continue
            seen = True
            role, text, ts = d.get("role"), d.get("text"), d.get("ts") or ""
            if role in ("user", "assistant") and isinstance(text, str) and text.strip():
                turns.append(Turn(role, text.strip(), ts))
        if not seen: return None, [], off
        started = turns[0].ts if turns else ""
        title = next((flat(t.text, 60) for t in turns if t.role == "user"), "") if offset == 0 else ""
        return SessionMeta("gemma", path.stem, "notch", "", started, title, str(path)), turns, off
