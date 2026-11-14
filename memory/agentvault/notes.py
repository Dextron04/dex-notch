"""Vault note writer. Notes are append-only markdown with JSON-valued frontmatter."""
import hashlib, json, os, re, tempfile, unicodedata
from pathlib import Path
from typing import Dict, List, Any, Tuple
from .model import Turn, SessionMeta
from .redact import redact

_KEYS = ["agent", "project", "cwd", "session_id", "title", "started", "updated", "turns", "source_path"]

def slug(s: str, n: int = 40) -> str:
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")[:n].strip("-") or "misc"

def note_path(vault: Path, meta: SessionMeta) -> Path:
    # filename is stable for a session: title is NOT in it (titles arrive late and change)
    date = meta.started[:10] if re.match(r"\d{4}-\d{2}-\d{2}", meta.started or "") else "0000-00-00"
    name = "%s-%s-%s.md" % (date, slug(meta.project), slug(meta.session_id, 80)[-10:].strip("-") or "x")
    return Path(vault) / "Sessions" / slug(meta.agent) / date[:7] / name

def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=".tmp-", delete=False, encoding="utf-8") as f:
        f.write(text)
    os.replace(f.name, path)

def _dump_fm(fm: Dict[str, Any]) -> str:
    return "---\n" + "".join("%s: %s\n" % (k, json.dumps(fm[k], ensure_ascii=False)) for k in _KEYS if k in fm) + "---\n"

def _parse_fm_lines(lines) -> Dict[str, Any]:
    fm = {}
    for ln in lines:
        k, _, v = ln.partition(": ")
        try: fm[k] = json.loads(v)
        except ValueError: fm[k] = v.strip()
    return fm

def read_frontmatter(path: Path) -> Dict[str, Any]:
    """Reads only the header of a note (cheap)."""
    lines = []
    with open(path, encoding="utf-8", errors="replace") as f:
        if f.readline().strip() != "---": return {}
        for ln in f:
            if ln.strip() == "---": break
            lines.append(ln.rstrip("\n"))
            if len(lines) > 40: break
    return _parse_fm_lines(lines)

_MARK = re.compile(r"<!-- t:([0-9a-f]{10}) -->")

def turn_key(t: Turn) -> str:
    return hashlib.sha1(("%s|%s|%s" % (t.role, t.ts, t.text)).encode("utf-8", "replace")).hexdigest()[:10]

def _render(t: Turn, key: str) -> str:
    text = redact(t.text).strip()
    if t.role == "tool":
        return "> %s · %s <!-- t:%s -->\n\n" % (t.ts, " ".join(text.split()), key)
    return "## %s · %s\n\n%s\n\n<!-- t:%s -->\n\n" % (t.role, t.ts, text, key)

def add_turns(vault: Path, meta: SessionMeta, turns: List[Turn]) -> Tuple[Path, int]:
    """Idempotent append: each section carries a hash marker, and turns already in the note are skipped.
    That makes state loss, crashes between note write and state save, and copies of a session harmless."""
    p = note_path(vault, meta)
    if p.exists():
        raw = p.read_text(encoding="utf-8")
        head, _, body = raw[4:].partition("\n---\n")
        fm = _parse_fm_lines(head.split("\n"))
        have = set(_MARK.findall(body))
    else:
        fm = {"agent": meta.agent, "project": meta.project, "cwd": meta.cwd, "session_id": meta.session_id,
              "started": meta.started, "updated": meta.started, "turns": 0, "source_path": meta.source_path}
        body = "\n# %s\n\n" % redact(meta.title or meta.project)
        have = set()
    fresh = []
    for t in turns:
        k = turn_key(t)
        if k not in have: have.add(k); fresh.append((t, k))
    if meta.title: fm["title"] = redact(meta.title)
    fm.setdefault("title", meta.project)
    fm["turns"] = int(fm.get("turns", 0)) + len(fresh)
    if fresh: fm["updated"] = max(fm.get("updated", ""), fresh[-1][0].ts)
    write_atomic(p, _dump_fm(fm) + body + "".join(_render(t, k) for t, k in fresh))
    return p, len(fresh)

def append_turns(vault: Path, meta: SessionMeta, turns: List[Turn]) -> Path:
    return add_turns(vault, meta, turns)[0]

def reset_note(vault: Path, meta: SessionMeta) -> None:
    p = note_path(vault, meta)
    if p.exists(): p.unlink()
