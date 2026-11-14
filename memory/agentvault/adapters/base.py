"""Adapter contract: turn an agent's raw session file into Turns, resumably.

parse(path, offset) -> (meta, turns, new_offset)
  * reads only COMPLETE lines at/after `offset`; a half-written trailing line is left for the next call
  * new_offset is the byte position just past the last complete line consumed
  * meta is None when the chunk had no records; otherwise it carries whatever this chunk knows
    (fields it doesn't know are ""). Callers merge: non-empty new values win, except session_id/started.
"""
import json
from pathlib import Path
from typing import Any, Iterator, List, Optional, Tuple
from ..model import Turn, SessionMeta
from ..redact import redact

class Adapter:
    name = ""
    def __init__(self, root=None):
        self.root = Path(root).expanduser() if root else self.default_root()
    def default_root(self) -> Path: raise NotImplementedError
    def discover(self) -> Iterator[Path]: raise NotImplementedError
    def parse(self, path: Path, offset: int) -> Tuple[Optional[SessionMeta], List[Turn], int]: raise NotImplementedError

def iter_json_lines(path: Path, offset: int) -> Iterator[Tuple[Optional[dict], int]]:
    """Streams (object-or-None, end_offset) per complete line; None = garbage line (still consumed)."""
    with open(path, "rb") as f:
        f.seek(offset)
        pos = offset
        for raw in f:
            if not raw.endswith(b"\n"):
                return  # partial last line: leave it for the next tick
            pos += len(raw)
            try: obj = json.loads(raw)
            except ValueError: obj = None
            yield (obj if isinstance(obj, dict) else None), pos

def flat(s: Any, n: int = 100) -> str:
    """Redact FIRST, then flatten and cut: a secret cut below a pattern's minimum length would otherwise slip through."""
    return " ".join(redact(str(s)).split())[:n]

_ARG_KEYS = ("command", "cmd", "file_path", "path", "pattern", "url", "query", "description")

def tool_line(name: str, args: Any = None) -> str:
    arg = ""
    if isinstance(args, dict):
        for k in _ARG_KEYS:
            if isinstance(args.get(k), str) and args[k].strip(): arg = args[k]; break
        else:
            arg = json.dumps(args, ensure_ascii=False)  # keep the argument NAMES so `"password": "..."` is caught by redaction
    elif isinstance(args, str): arg = args
    return ("ran: %s %s" % (name, flat(arg))).strip()
