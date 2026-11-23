"""Notch chats the user chose to save to the vault: ~/Library/Application Support/NotchApp/journal/<conversation-id>.jsonl, one JSON
object per line {"v":1,"conv","role":"user|assistant","text","ts","model"}, appended by the app only when the user presses "Save to vault".
Notch chats are otherwise local only: the recorder skips the Claude/Codex sessions the notch launches (see recorder.is_notch_private)."""
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
        turns, off, seen, model = [], offset, False, "gemma"
        for d, end in iter_json_lines(path, offset):
            off = end
            if not d: continue
            seen = True
            if isinstance(d.get("model"), str) and d["model"]: model = d["model"]
            role, text, ts = d.get("role"), d.get("text"), d.get("ts") or ""
            if role in ("user", "assistant") and isinstance(text, str) and text.strip():
                turns.append(Turn(role, text.strip(), ts))
        if not seen: return None, [], off
        started = turns[0].ts if turns else ""
        title = next((flat(t.text, 60) for t in turns if t.role == "user"), "") if offset == 0 else ""
        return SessionMeta(model, path.stem, "notch", "", started, title, str(path)), turns, off
