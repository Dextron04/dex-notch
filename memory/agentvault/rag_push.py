"""Feeds the vault into the mac-mini's RAG through its own authenticated push endpoint (POST /rag/ingest) as machine "vault".
The tunnel in front drops requests slower than ~100s, so notes go in small batches and long notes are split into parts."""
import hashlib, json, re, subprocess, urllib.error, urllib.request
from pathlib import Path
from typing import Callable, Dict, List, Optional
from .index import session_files
from .notes import read_frontmatter, write_atomic

TARGET = "https://ai.example.com"
KEYCHAIN = ("ai.example.com", "notchapp")
MAX_DOC_BYTES = 100_000     # one part of a long note
BATCH_BYTES = 250_000       # one request
USER_AGENT = "agentvault/0.1"  # Cloudflare rejects Python's default agent

class PushError(Exception):
    pass

_MARK = re.compile(r" ?<!-- t:[0-9a-f]{10} -->")
_TOOL = re.compile(r"^> \S+ · ran: .*$\n?", re.M)

_LINKS = re.compile(r"^\[\[Projects/.*$\n?", re.M)  # graph links for Obsidian; noise for retrieval

def _clean(body: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", _LINKS.sub("", _MARK.sub("", _TOOL.sub("", body)))).strip()

def _split(text: str, limit: int) -> List[str]:
    parts, cur, size = [], [], 0
    for para in text.split("\n\n"):
        n = len(para.encode()) + 2
        if cur and size + n > limit: parts.append("\n\n".join(cur)); cur, size = [], 0
        while n > limit:  # a single huge paragraph: hard cut
            head, para = para[:limit // 2], para[limit // 2:]; parts.append(head); n = len(para.encode()) + 2
        cur.append(para); size += n
    if cur: parts.append("\n\n".join(cur))
    return parts

def build_docs(vault: Path) -> List[dict]:
    vault, docs = Path(vault), []
    for p in session_files(vault):
        fm = read_frontmatter(p)
        raw = p.read_text(encoding="utf-8", errors="replace")
        body = _clean(raw.split("\n---\n", 1)[-1])
        body = re.sub(r"^# .*\n+", "", body, count=1)  # the H1 is the title; it goes in the header instead
        rel = p.relative_to(vault).as_posix()
        title = fm.get("title", p.stem)
        head = "agent: %s · project: %s · %s\n\n" % (fm.get("agent", ""), fm.get("project", ""), fm.get("updated", "")[:10])
        parts = _split(body, MAX_DOC_BYTES) or [""]
        for i, part in enumerate(parts, 1):
            docs.append({"id": rel if len(parts) == 1 else "%s#%d" % (rel, i),
                         "title": title if len(parts) == 1 else "%s (part %d)" % (title, i),
                         "source": "vault:" + rel, "text": head + part})
    return docs

def _digest(d: dict) -> str:
    return hashlib.sha1(("\0".join((d["title"], d["source"], d["text"]))).encode("utf-8", "replace")).hexdigest()

def _load(path: Path) -> Dict[str, str]:
    try: return json.loads(path.read_text())
    except (OSError, ValueError): return {}  # losing this file only means one redundant (idempotent) push

def keychain_key() -> str:
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN[0], "-a", KEYCHAIN[1], "-w"],
                       capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip(): raise PushError("no API token in Keychain for %s" % KEYCHAIN[0])
    return r.stdout.strip()

def post_http(payload: dict, key: str, target: str = TARGET) -> dict:
    req = urllib.request.Request(target.rstrip("/") + "/rag/ingest", json.dumps(payload).encode(),
                                 {"Content-Type": "application/json", "User-Agent": USER_AGENT, "Authorization": "Bearer " + key})
    try:
        with urllib.request.urlopen(req, timeout=180) as r: return json.load(r)
    except urllib.error.HTTPError as e: raise PushError("ingest returned HTTP %d" % e.code) from e
    except (urllib.error.URLError, OSError, ValueError) as e: raise PushError("ingest failed: %s" % e) from e

def sync(vault: Path, post: Optional[Callable[[dict], dict]] = None, state_path: Optional[Path] = None,
         batch_bytes: int = BATCH_BYTES) -> Dict[str, int]:
    """Pushes only notes whose content changed. State is saved per batch, so a failure resumes where it stopped.
    Bundles are always `complete: false`, so the service never deletes anything on our account."""
    vault = Path(vault)
    state_path = Path(state_path) if state_path else vault / ".recorder" / "rag_state.json"
    if post is None:
        key = keychain_key(); post = lambda payload: post_http(payload, key)
    state = _load(state_path)
    docs = build_docs(vault)
    todo = [d for d in docs if state.get(d["id"]) != _digest(d)]
    pushed = 0
    batch: List[dict] = []; size = 0
    def flush():
        nonlocal batch, size, pushed
        if not batch: return
        post({"machine": "vault", "documents": batch, "complete": False})
        for d in batch: state[d["id"]] = _digest(d)
        write_atomic(state_path, json.dumps(state)); pushed += len(batch); batch, size = [], 0
    for d in todo:
        n = len(json.dumps(d))
        if batch and size + n > batch_bytes: flush()
        batch.append(d); size += n
    flush()
    return {"pushed": pushed, "skipped": len(docs) - len(todo), "total": len(docs)}

_key_cache: List[str] = []

def semantic_paths(query: str, target: str = TARGET) -> List[str]:
    """Vault notes the RAG judges relevant to `query` (relative paths). Short timeout: search must never hang on the network."""
    if not _key_cache: _key_cache.append(keychain_key())
    body = json.dumps({"messages": [{"role": "user", "content": query}]}).encode()
    req = urllib.request.Request(target.rstrip("/") + "/rag/search", body, {"Content-Type": "application/json",
                                 "User-Agent": USER_AGENT, "Authorization": "Bearer " + _key_cache[0]})
    with urllib.request.urlopen(req, timeout=4) as r: sources = json.load(r).get("sources", [])
    out: List[str] = []
    for s in sources:
        src = s.get("source", "")
        if src.startswith("vault:") and src[6:] not in out: out.append(src[6:])
    return out
