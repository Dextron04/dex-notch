import shutil, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import notes, remote_sync
from agentvault.model import Turn, SessionMeta

def note(vault, agent, sid, title):
    notes.add_turns(vault, SessionMeta(agent, sid, "chats", "", "2026-11-14T10:00:00Z", title, "/s"), [Turn("assistant", "body " + title, "2026-11-14T10:00:00Z")])[0]

@unittest.skipUnless(shutil.which("rsync"), "rsync needed")
class RemoteSyncTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.vault, self.target = Path(self.d.name) / "Vault", Path(self.d.name) / "remote"
        (self.target / "Sessions").mkdir(parents=True)
        note(self.vault, "codex", "aaaaaaaaaa1", "Local codex note")
        note(self.target, "chatgpt", "bbbbbbbbbb2", "Saved from ChatGPT")

    def test_push_local_sessions_and_pull_remote_origin_ones(self):
        r = remote_sync.sync(self.vault, str(self.target))
        self.assertEqual(r["pushed"], 1)
        self.assertTrue(list((self.target / "Sessions" / "codex").rglob("*.md")))          # pushed
        self.assertTrue(list((self.vault / "Sessions" / "chatgpt").rglob("*.md")))         # pulled
        self.assertEqual(r["pulled"], 1)
        self.assertIn("chatgpt", (self.vault / "Index.md").read_text())                     # hubs rebuilt for the pulled note

    def test_pulls_reminders_set_remotely(self):
        (self.target / "Reminders").mkdir()
        (self.target / "Reminders" / "r1.md").write_text('---\nid: "r1"\ndue: "2026-11-16T15:00:00Z"\ntext: "call mum"\n---\n')
        remote_sync.sync(self.vault, str(self.target))
        self.assertTrue((self.vault / "Reminders" / "r1.md").exists())

    def test_push_never_deletes_remote_origin_notes(self):
        remote_sync.sync(self.vault, str(self.target))
        self.assertTrue(list((self.target / "Sessions" / "chatgpt").rglob("*.md")))

    def test_pull_does_not_push_remote_origin_back_and_second_run_is_quiet(self):
        remote_sync.sync(self.vault, str(self.target))
        self.assertEqual(remote_sync.sync(self.vault, str(self.target))["pulled"], 0)

    def test_push_removes_notes_deleted_locally(self):
        remote_sync.sync(self.vault, str(self.target))
        for p in (self.vault / "Sessions" / "codex").rglob("*.md"): p.unlink()
        remote_sync.sync(self.vault, str(self.target))
        self.assertFalse(list((self.target / "Sessions" / "codex").rglob("*.md")))

    def test_unreachable_target_raises_not_silently_ok(self):
        with self.assertRaises(RuntimeError): remote_sync.sync(self.vault, "/nonexistent-dir-xyz/Vault")

if __name__ == "__main__": unittest.main()
