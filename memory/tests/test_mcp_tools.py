"""The MCP stdio server: every listed tool is called over the real process and answers; bad input is an error result, not a crash."""
import json, subprocess, sys, tempfile, unittest
from pathlib import Path
MEM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MEM))
from agentvault import mcp_server, notes
from agentvault.model import Turn, SessionMeta

class McpToolTests(unittest.TestCase):
    def test_every_listed_tool_can_be_called_over_stdio(self):
        with tempfile.TemporaryDirectory() as d:
            notes.add_turns(Path(d), SessionMeta("claude-code", "bbbbbbbbbb2", "app", "/x/app", "2026-11-14T10:00:00Z", "Pear tart recipe", "/s"),
                               [Turn("user", "how long do pears bake", "2026-11-14T10:00:00Z")])
            def rpc(reqs):
                p = subprocess.run([sys.executable, "-m", "agentvault.mcp_server", "--vault", d], cwd=MEM, timeout=20, capture_output=True, text=True,
                                   input="".join(json.dumps(r) + "\n" for r in reqs))
                return {r["id"]: r for r in (json.loads(l) for l in p.stdout.splitlines())}
            listed = rpc([{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])[1]["result"]["tools"]
            self.assertEqual(sorted(t["name"] for t in listed), sorted(t["name"] for t in mcp_server.TOOLS))
            for t in listed: self.assertEqual(t["inputSchema"]["type"], "object")
            text = lambda r: r["result"]["content"][0]["text"]
            call = lambda i, n, a: {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": n, "arguments": a}}
            out = rpc([call(1, "vault_search", {"query": "pears"}), call(2, "vault_recent", {"n": 3}), call(3, "vault_recent", {"agent": "codex"})])
            hit = json.loads(text(out[1]))[0]; self.assertIn("Pear tart", json.dumps(hit))
            self.assertIn("Pear tart", text(out[2])); self.assertEqual(json.loads(text(out[3])), [])          # another agent has nothing
            out = rpc([call(1, "vault_read", {"path": hit["path"]}), call(2, "vault_read", {"path": hit["path"], "offset": 5, "limit": 10})])
            self.assertIn("how long do pears bake", text(out[1])); self.assertLessEqual(len(text(out[2])), 200)
            out = rpc([call(1, "no_such_tool", {}), call(2, "vault_search", {}), {"jsonrpc": "2.0", "id": 3, "method": "ping"}])
            self.assertTrue(out[1]["result"]["isError"]); self.assertTrue(out[2]["result"]["isError"]); self.assertEqual(out[3]["result"], {})

if __name__ == "__main__": unittest.main()
