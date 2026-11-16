import json, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.hosted import ingest, tools
from agentvault.hosted.store import Store

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"

@unittest.skipUnless(shutil.which("sqlite3") and shutil.which("tar"), "needs the sqlite3 and tar command line tools")
class BackupTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.root, self.out = Path(self.d.name) / "data", Path(self.d.name) / "backups"
        self.s = Store(self.root); self.u = self.s.create_user("a@x.io"); self.s.grant(self.u)
        ingest.ingest(self.s, self.u, {"sessions": [{"meta": {"agent": "codex", "session_id": "s1", "project": "p", "cwd": "/x", "started": "2026-11-14T10:00:00Z", "title": "T"},
                                                      "turns": [{"role": "user", "text": "remember the pineapple", "ts": "2026-11-14T10:00:00Z"}]}]})
        self.env = dict(os.environ, HOSTED_ROOT=str(self.root), HOSTED_BACKUPS=str(self.out), KEEP="3")

    def run_script(self, name, *args, env=None):
        return subprocess.run(["/bin/bash", str(SCRIPTS / name), *args], capture_output=True, text=True, env=env or self.env)

    def test_backup_then_restore_brings_everything_back(self):
        r = self.run_script("hosted-backup.sh"); self.assertEqual(r.returncode, 0, r.stderr); self.assertIn("backup ok", r.stdout)
        arch = next(self.out.glob("hosted-*.tar.gz")); self.assertEqual(oct(arch.stat().st_mode & 0o777), "0o600")      # private chats: owner only
        self.s.delete_account(self.u)                                                                                       # disaster
        dest = Path(self.d.name) / "restored"
        r = self.run_script("hosted-restore.sh", str(arch), str(dest)); self.assertEqual(r.returncode, 0, r.stderr); self.assertIn("1 user(s) and 1 note(s)", r.stdout)
        back = Store(dest)
        self.assertEqual((back.status(self.u), back.by_email("a@x.io")), ("active", self.u))
        self.assertIn("pineapple", tools.call(back, self.u, "vault_search", {"query": "pineapple"}))

    def test_restore_refuses_a_folder_with_anything_in_it(self):
        self.run_script("hosted-backup.sh"); arch = next(self.out.glob("hosted-*.tar.gz"))
        dest = Path(self.d.name) / "busy"; dest.mkdir(); (dest / "keep.txt").write_text("mine")
        r = self.run_script("hosted-restore.sh", str(arch), str(dest)); self.assertNotEqual(r.returncode, 0); self.assertEqual((dest / "keep.txt").read_text(), "mine")

    def test_keeps_only_the_newest_and_a_corrupt_database_saves_nothing(self):
        self.out.mkdir()
        for i in range(5): (self.out / ("hosted-2026010%d-000000.tar.gz" % (i + 1))).write_bytes(b"x"); os.utime(self.out / ("hosted-2026010%d-000000.tar.gz" % (i + 1)), (1000 + i, 1000 + i))
        self.assertEqual(self.run_script("hosted-backup.sh").returncode, 0)
        kept = sorted(p.name for p in self.out.glob("hosted-*.tar.gz"))
        self.assertEqual(len(kept), 3); self.assertEqual(kept[:2], ["hosted-20260104-000000.tar.gz", "hosted-20260105-000000.tar.gz"])   # the 2 newest old ones, plus today's
        (self.root / "hosted.db").write_bytes(b"this is not a database" * 100)
        r = self.run_script("hosted-backup.sh"); self.assertNotEqual(r.returncode, 0); self.assertEqual(sorted(p.name for p in self.out.glob("hosted-*.tar.gz")), kept)

if __name__ == "__main__": unittest.main()
