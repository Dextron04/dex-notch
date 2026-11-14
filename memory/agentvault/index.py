"""Index.md and Agents/<agent>.md: newest sessions first, as Obsidian wikilinks."""
from pathlib import Path
from typing import List, Tuple
from .notes import read_frontmatter, write_atomic

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
    for agent in sorted({r[1] for r in rows}):
        mine = [r for r in rows if r[1] == agent][:LIMIT]
        write_atomic(vault / "Agents" / ("%s.md" % agent), "# %s\n\n" % agent + "".join(_line(vault, p, fm) for _, _, p, fm in mine))
