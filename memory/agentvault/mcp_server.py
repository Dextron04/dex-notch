"""Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0). Tools: vault_search, vault_recent, vault_read."""
import argparse, json, sys
from dataclasses import asdict
from pathlib import Path
from . import rag_push, search as S

TOOLS = [
    {"name": "vault_search", "title": "Search past conversations", "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False}, "description": "Search past conversations across all agents (Claude Code, Codex, Gemini) recorded in the shared Obsidian vault.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}, "agent": {"type": "string", "description": "claude-code | codex | gemini"},
                     "since": {"type": "string", "description": "ISO date, e.g. 2026-11-01"}}, "required": ["query"]}},
    {"name": "vault_recent", "title": "List recent conversations", "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False}, "description": "List the most recent recorded conversations, optionally for one agent.",
     "inputSchema": {"type": "object", "properties": {"agent": {"type": "string"}, "n": {"type": "integer"}}}},
    {"name": "vault_read", "title": "Read a conversation note", "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False}, "description": "Read one recorded conversation note by the relative path returned from vault_search/vault_recent.",
     "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}, "offset": {"type": "integer", "description": "start character; notes are returned in pages of 20000 chars"}, "limit": {"type": "integer"}}, "required": ["path"]}},
]

def call(vault: Path, name: str, a: dict) -> str:
    if name == "vault_search": return json.dumps([asdict(h) for h in S.search(vault, a["query"], a.get("agent"), a.get("since"), semantic=rag_push.semantic_paths)], indent=1)
    if name == "vault_recent": return json.dumps([asdict(h) for h in S.recent(vault, a.get("agent"), int(a.get("n", 5)))], indent=1)
    if name == "vault_read": return S.read(vault, a["path"], int(a.get("offset", 0)), int(a.get("limit", S.READ_LIMIT)))
    raise KeyError(name)

def handle(req: dict, vault: Path, extra=None):
    """Returns a response dict, or None for notifications. `extra` = (tool schemas, fn(name, args) -> str | None) adds tools (remote connector)."""
    rid, method, params = req.get("id"), req.get("method", ""), req.get("params") or {}
    if rid is None: return None  # notification
    ok = lambda r: {"jsonrpc": "2.0", "id": rid, "result": r}
    if method == "initialize":
        return ok({"protocolVersion": params.get("protocolVersion", "2024-11-05"), "capabilities": {"tools": {}},
                   "serverInfo": {"name": "agentvault", "version": "0.1.0"}})
    if method == "ping": return ok({})
    if method == "tools/list": return ok({"tools": TOOLS + (extra[0] if extra else [])})
    if method == "tools/call":
        try:
            name, args = params.get("name", ""), params.get("arguments") or {}
            text = extra[1](name, args) if extra else None
            return ok({"content": [{"type": "text", "text": text if text is not None else call(vault, name, args)}]})
        except Exception as e: return ok({"content": [{"type": "text", "text": "error: %s" % e}], "isError": True})
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found: %s" % method}}

def main() -> None:
    ap = argparse.ArgumentParser(); ap.add_argument("--vault", default="~/Vault")
    vault = Path(ap.parse_args().vault).expanduser()
    for line in sys.stdin:
        if not line.strip(): continue
        try: resp = handle(json.loads(line), vault)
        except Exception as e: resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": str(e)}}
        if resp is not None: print(json.dumps(resp), flush=True)

if __name__ == "__main__":
    main()
