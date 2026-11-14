"""Read side of the vault: plain-text search, recent sessions, safe note read."""
import re
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional
from .index import session_files
from .notes import read_frontmatter

@dataclass
class Hit:
    path: str       # relative to the vault, e.g. Sessions/codex/2026-11/....md
    agent: str
    project: str
    title: str
    updated: str
    snippet: str

def _hit(vault: Path, p: Path, fm: dict, snippet: str = "") -> Hit:
    return Hit(p.relative_to(vault).as_posix(), fm.get("agent", ""), fm.get("project", ""),
               fm.get("title", p.stem), fm.get("updated", ""), snippet)

def _rows(vault: Path, agent: Optional[str], since: Optional[str]):
    for p in session_files(vault):
        fm = read_frontmatter(p)
        if agent and fm.get("agent") != agent: continue
        if since and fm.get("updated", "") < since: continue
        yield p, fm

def search(vault: Path, query: str, agent: Optional[str] = None, since: Optional[str] = None, limit: int = 10) -> List[Hit]:
    vault = Path(vault)
    terms = [re.escape(t) for t in query.split() if t]
    if not terms: return []
    rx = re.compile("|".join(terms), re.IGNORECASE)
    scored = []
    for p, fm in _rows(vault, agent, since):
        text = p.read_text(encoding="utf-8", errors="replace")
        body = text.split("\n---\n", 1)[-1]
        found = list(rx.finditer(body))
        if not found: continue
        a = max(0, found[0].start() - 80)
        snippet = " ".join(body[a:found[0].end() + 120].split())
        scored.append((len(found), fm.get("updated", ""), _hit(vault, p, fm, snippet)))
    scored.sort(key=lambda r: (r[0], r[1]), reverse=True)
    return [r[2] for r in scored[:limit]]

def recent(vault: Path, agent: Optional[str] = None, n: int = 5) -> List[Hit]:
    vault = Path(vault)
    rows = sorted(_rows(vault, agent, None), key=lambda r: r[1].get("updated", ""), reverse=True)
    return [_hit(vault, p, fm) for p, fm in rows[:n]]

def read(vault: Path, rel_path: str) -> str:
    """Only .md files strictly inside the vault (symlinks resolved), never dot-directories."""
    if not rel_path or Path(rel_path).is_absolute(): raise ValueError("path must be relative to the vault")
    root = Path(vault).resolve()
    p = (root / rel_path).resolve()
    if not p.is_relative_to(root): raise ValueError("path escapes the vault")
    rp = p.relative_to(root)
    if p.suffix != ".md" or rp.parts[0].startswith(".") or not p.is_file(): raise ValueError("not a vault note")
    return p.read_text(encoding="utf-8", errors="replace")
