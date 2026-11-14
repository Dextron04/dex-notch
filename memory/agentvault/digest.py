"""Startup digest for Claude Code (approach B). Hard-capped so it can never eat a session's context."""
import os
from pathlib import Path
from typing import List
from .search import recent, Hit

def _line(h: Hit) -> str:
    return "- %s %s (%s)" % (h.updated[:10], " ".join(h.title.split())[:60], h.project)

def build_digest(vault: Path, cwd: str, max_chars: int = 1600) -> str:
    vault = Path(vault)
    if not vault.exists(): return ""
    proj = os.path.basename(cwd.rstrip("/"))
    allrecent = recent(vault, n=10000)
    if not allrecent: return ""
    lines: List[str] = ["Shared memory: recent work across your agents. Use the vault_search / vault_read tools for details."]
    mine = [h for h in allrecent if proj and h.project == proj][:3]
    if mine: lines += ["This project (%s):" % proj] + [_line(h) for h in mine]
    for agent in sorted({h.agent for h in allrecent}):
        group = [h for h in allrecent if h.agent == agent][:3]
        lines += ["%s:" % agent] + [_line(h) for h in group]
    out, size = [], 0
    for ln in lines:  # stop at the budget, on a line boundary
        if size + len(ln) + 1 > max_chars: break
        out.append(ln); size += len(ln) + 1
    return "\n".join(out)
