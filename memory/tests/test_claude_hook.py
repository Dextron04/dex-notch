import json, subprocess, sys, tempfile, unittest
from pathlib import Path
MEM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MEM))
import claude_hook

class HookInstall(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.addCleanup(self._t.cleanup)
        self.f = Path(self._t.name) / ".claude" / "settings.json"
        self.backup = self.f.with_name("settings.json.dex-backup")
    def load(self): return json.loads(self.f.read_text())
    def ours(self): return [g for g in self.load()["hooks"]["SessionStart"] if claude_hook._ours(g)]

    def test_creates_the_file_when_there_is_none(self):
        claude_hook.run("add", self.f)
        self.assertEqual(len(self.ours()), 1)
        self.assertIn("hooks/session_start.py", self.ours()[0]["hooks"][0]["command"])

    def test_merges_keeps_everything_else_and_backs_up(self):
        self.f.parent.mkdir(parents=True)
        mine = {"hooks": [{"type": "command", "command": "echo hi"}]}
        orig = {"model": "opus", "permissions": {"allow": ["Bash(ls)"]}, "hooks": {"SessionStart": [mine], "Stop": [{"hooks": [{"type": "command", "command": "x"}]}]}}
        self.f.write_text(json.dumps(orig))
        claude_hook.run("add", self.f)
        cfg = self.load()
        self.assertEqual(cfg["model"], "opus"); self.assertEqual(cfg["permissions"], orig["permissions"]); self.assertEqual(cfg["hooks"]["Stop"], orig["hooks"]["Stop"])
        self.assertEqual(cfg["hooks"]["SessionStart"][0], mine); self.assertEqual(len(self.ours()), 1)
        self.assertEqual(json.loads(self.backup.read_text()), orig)

    def test_idempotent_and_no_rewrite_when_nothing_changes(self):
        claude_hook.run("add", self.f); first = self.f.read_text()
        self.assertIn("nothing to change", claude_hook.run("add", self.f))
        self.assertEqual(self.f.read_text(), first); self.assertEqual(len(self.ours()), 1)
        self.assertFalse(self.backup.exists())          # nothing changed, so nothing was backed up (the first add had no file to back up)

    def test_a_vault_is_passed_to_the_hook_and_a_rerun_updates_the_same_entry(self):
        claude_hook.run("add", self.f); claude_hook.run("add", self.f, vault="/my vault")
        self.assertEqual(len(self.ours()), 1); self.assertIn("AGENTVAULT_VAULT='/my vault'", self.ours()[0]["hooks"][0]["command"])

    def test_remove_takes_only_ours_and_tidies_up(self):
        other = {"hooks": [{"type": "command", "command": "echo hi"}]}
        self.f.parent.mkdir(parents=True); self.f.write_text(json.dumps({"hooks": {"SessionStart": [other]}}))
        claude_hook.run("add", self.f); claude_hook.run("remove", self.f)
        self.assertEqual(self.load()["hooks"]["SessionStart"], [other])
        self.f.write_text("{}"); claude_hook.run("add", self.f); claude_hook.run("remove", self.f)
        self.assertEqual(self.load(), {})

    def test_broken_or_odd_files_are_left_alone(self):
        self.f.parent.mkdir(parents=True)
        for text in ("{not json", "[1]", '{"hooks": []}', '{"hooks": {"SessionStart": 5}}'):
            self.f.write_text(text)
            with self.assertRaises(ValueError, msg=text): claude_hook.run("add", self.f)
            self.assertEqual(self.f.read_text(), text)

    def test_the_script_it_points_at_exists_and_prints_json(self):
        self.assertTrue(claude_hook.SCRIPT.exists())
        with tempfile.TemporaryDirectory() as v:
            p = subprocess.run([sys.executable, str(claude_hook.SCRIPT)], input="{}", capture_output=True, text=True, timeout=10, env={"AGENTVAULT_VAULT": v})
        json.loads(p.stdout); self.assertEqual(p.returncode, 0)

    def test_install_sh_registers_the_hook_and_has_valid_syntax(self):
        self.assertIn("claude_hook.py", (MEM / "install.sh").read_text())
        self.assertEqual(subprocess.run(["sh", "-n", str(MEM / "install.sh")]).returncode, 0)

if __name__ == "__main__": unittest.main()
