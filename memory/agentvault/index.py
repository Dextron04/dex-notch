"""Index.md and Agents/<agent>.md: newest sessions first, as Obsidian wikilinks."""
from pathlib import Path
from typing import List, Tuple
import re
from .notes import read_frontmatter, slug, write_atomic

LIMIT = 50

def session_files(vault: Path):
    """All real session notes (never sync-conflict copies)."""
    return [p for p in sorted(Path(vault).glob("Sessions/*/*/*.md")) if ".sync-conflict-" not in p.name]

def _line(vault: Path, p: Path, fm) -> str:
    rel = p.relative_to(vault).with_suffix("").as_posix()
    return "- [[%s|%s]] · %s · %s · %s\n" % (rel, fm.get("title", p.stem), fm.get("agent", ""), fm.get("project", ""), fm.get("updated", ""))

def rebuild_indexes(vault: Path) -> None:
    vault = Path(vault)
    rows: List[Tuple[str, str, Path, dict]] = []
    for p in session_files(vault):
        fm = read_frontmatter(p)
        rows.append((fm.get("updated", ""), fm.get("agent", p.parent.parent.name), p, fm))
    rows.sort(key=lambda r: r[0], reverse=True)
    write_atomic(vault / "Index.md", "# Index\n\n" + "".join(_line(vault, p, fm) for _, _, p, fm in rows[:LIMIT]))
    hubs = {}  # relative hub path -> (heading, [rows])
    for r in rows:
        fm = r[3]
        day = fm.get("started", "")[:10]
        keys = [("Projects/%s.md" % slug(fm.get("project", "")), fm.get("project", "") or "misc")]
        if re.match(r"\d{4}-\d{2}-\d{2}$", day): keys.append(("Days/%s.md" % day, day))
        for rel, heading in keys: hubs.setdefault(rel, (heading, []))[1].append(r)
    for rel, (heading, members) in hubs.items():  # rows are already newest-first
        write_atomic(vault / rel, "# %s\n\n" % heading + "".join(_line(vault, p, fm) for _, _, p, fm in members[:200]))
    for agent in sorted({r[1] for r in rows}):
        mine = [r for r in rows if r[1] == agent][:LIMIT]
        write_atomic(vault / "Agents" / ("%s.md" % agent), "# %s\n\n" % agent + "".join(_line(vault, p, fm) for _, _, p, fm in mine))
