import json, subprocess, sys, tempfile, unittest
from pathlib import Path
MEM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MEM))
from agentvault import notes
from agentvault.model import Turn, SessionMeta

class McpTests(unittest.TestCase):
    def test_mcp_initialize_list_call_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            v = Path(d)
            notes.add_turns(v, SessionMeta("codex", "aaaaaaaaaa1", "auth", "/x/auth", "2026-11-14T10:00:00Z", "Auth lock fix", "/s"),
                               [Turn("user", "why does the keychain prompt appear", "2026-11-14T10:00:00Z")])[0]
            reqs = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "vault_search", "arguments": {"query": "keychain"}}},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "vault_read", "arguments": {"path": "../../etc/passwd"}}},
                {"jsonrpc": "2.0", "id": 5, "method": "nope"},
            ]
            p = subprocess.run([sys.executable, "-m", "agentvault.mcp_server", "--vault", d], cwd=MEM, timeout=20,
                               input="".join(json.dumps(r) + "\n" for r in reqs), capture_output=True, text=True)
            out = {r["id"]: r for r in (json.loads(l) for l in p.stdout.splitlines())}
            self.assertEqual(sorted(out), [1, 2, 3, 4, 5])  # the notification gets no reply
            self.assertIn("tools", out[1]["result"]["capabilities"])
            self.assertEqual(sorted(t["name"] for t in out[2]["result"]["tools"]), ["vault_read", "vault_recent", "vault_search"])
            self.assertIn("Auth lock fix", out[3]["result"]["content"][0]["text"])
            self.assertTrue(out[4]["result"]["isError"])
            self.assertEqual(out[5]["error"]["code"], -32601)

if __name__ == "__main__":
    unittest.main()
