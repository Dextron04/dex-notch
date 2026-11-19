import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
MEM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MEM))
from agentvault import notes, digest
from agentvault.model import Turn, SessionMeta

def add(v, sid, agent, project, title, day):
    ts = "2026-11-%02dT10:00:00Z" % day
    notes.add_turns(v, SessionMeta(agent, sid, project, "/x/" + project, ts, title, "/s"), [Turn("user", "x", ts)])[0]

class DigestTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.v = Path(self._t.name)
    def tearDown(self): self._t.cleanup()

    def test_digest_under_budget_with_many_sessions(self):
        for i in range(60): add(self.v, "id%08d" % i, ["claude-code", "codex", "gemini"][i % 3], "proj%d" % (i % 5), "A fairly long session title number %d about things" % i, 1 + i % 28)
        d = digest.build_digest(self.v, "/Users/x/proj1")
        self.assertLessEqual(len(d), 1600); self.assertIn("vault_search", d)

    def test_empty_vault_gives_empty_digest(self):
        self.assertEqual(digest.build_digest(self.v, "/x/notch"), "")
        self.assertEqual(digest.build_digest(self.v / "missing", "/x/notch"), "")

    def test_project_matches_listed_first(self):
        add(self.v, "aaaaaaaaaa1", "codex", "other", "Other work", 14)
        add(self.v, "bbbbbbbbbb2", "claude-code", "notch", "Notch work", 3)
        d = digest.build_digest(self.v, "/Users/x/notch")
        self.assertLess(d.index("Notch work"), d.index("Other work"))
        self.assertIn("notch", d.splitlines()[1].lower())

    def test_hook_prints_valid_json_and_exits_zero_on_missing_vault(self):
        r = subprocess.run([sys.executable, str(MEM / "hooks" / "session_start.py")], input='{"cwd": "/x/notch"}',
                           capture_output=True, text=True, timeout=10, env=dict(os.environ, AGENTVAULT_VAULT="/nonexistent/vault"))
        self.assertEqual(r.returncode, 0); self.assertEqual(json.loads(r.stdout), {})

    def test_hook_emits_additional_context(self):
        add(self.v, "aaaaaaaaaa1", "claude-code", "notch", "Notch work", 14)
        r = subprocess.run([sys.executable, str(MEM / "hooks" / "session_start.py")], input='{"cwd": "/x/notch"}',
                           capture_output=True, text=True, timeout=10, env=dict(os.environ, AGENTVAULT_VAULT=str(self.v)))
        out = json.loads(r.stdout)["hookSpecificOutput"]
        self.assertEqual(out["hookEventName"], "SessionStart"); self.assertIn("Notch work", out["additionalContext"])

if __name__ == "__main__":
    unittest.main()
