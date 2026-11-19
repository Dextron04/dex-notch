"""Reminder lifecycle, the unreadable-reminder stream, and account deletion that fails part-way."""
import sys, tempfile, unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentvault import reminder_stream, seal
from agentvault.hosted import devices, tools
from agentvault.hosted import store as store_mod
from agentvault.hosted.store import DeleteIncomplete, Store
from agentvault.remote.tools import is_retired, remind, retire_reminders

def fmt(dt): return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
def body(due, rid="a" * 16): return '---\nid: "%s"\ndue: "%s"\ntext: "x"\nsource: "claude-web"\ncreated: "2026-01-01T00:00:00Z"\n---\n' % (rid, fmt(due))
NOW = datetime(2026, 11, 20, 12, 0, tzinfo=timezone.utc)

class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.addCleanup(self.t.cleanup); self.v = Path(self.t.name); (self.v / "Reminders").mkdir()

    def put(self, name, text): (self.v / "Reminders" / name).write_text(text)

    def test_retired_only_after_the_two_day_grace(self):
        self.assertFalse(is_retired(body(NOW + timedelta(days=5)), NOW)); self.assertFalse(is_retired(body(NOW - timedelta(days=1, hours=23)), NOW))
        self.assertTrue(is_retired(body(NOW - timedelta(days=2, minutes=1)), NOW))
        for junk in ("", "no front matter", '---\ndue: "tomorrow"\n---\n'): self.assertFalse(is_retired(junk, NOW))   # never delete what we can't read

    def test_retire_deletes_old_keeps_pending_and_unreadable(self):
        self.put("%016x.md" % 1, body(NOW - timedelta(days=3))); self.put("%016x.md" % 2, body(NOW - timedelta(hours=2))); self.put("%016x.md" % 3, body(NOW + timedelta(days=1))); self.put("%016x.md" % 4, "junk")
        self.assertEqual(retire_reminders(self.v, NOW), 1)
        self.assertEqual(sorted(p.name for p in (self.v / "Reminders").glob("*.md")), ["%016x.md" % i for i in (2, 3, 4)])

    def test_a_locked_file_is_left_alone(self):
        self.put("%016x.md" % 1, body(NOW - timedelta(days=9)))
        with mock.patch.object(seal, "read_text", side_effect=seal.Locked()): self.assertEqual(retire_reminders(self.v, NOW), 0)
        self.assertEqual(len(list((self.v / "Reminders").glob("*.md"))), 1)

    def test_the_connector_stream_does_not_bring_back_a_retired_reminder(self):
        old, fresh = body(datetime.now(timezone.utc) - timedelta(days=5), "1" * 16), body(datetime.now(timezone.utc) + timedelta(days=1), "2" * 16)
        n = reminder_stream.store(self.v, [{"name": "1" * 16 + ".md", "content": old}, {"name": "2" * 16 + ".md", "content": fresh}])
        self.assertEqual(n, 1); self.assertFalse((self.v / "Reminders" / ("1" * 16 + ".md")).exists())

    def test_the_cap_counts_only_pending_reminders(self):
        d = tempfile.TemporaryDirectory(); self.addCleanup(d.cleanup)
        s = Store(Path(d.name)); u = s.create_user("a@x.io"); s.grant(u)
        r = s.user_vault(u) / "Reminders"; r.mkdir(parents=True)
        for i in range(tools.MAX_PENDING_REMINDERS): (r / ("%016x.md" % i)).write_text(body(datetime.now(timezone.utc) - timedelta(days=30)))
        when = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
        self.assertIn("Reminder set", tools.call(s, u, "remind", {"text": "fresh", "when": when, "source": "claude"}))   # the old thousand were cleared, not counted
        self.assertEqual(len(list(r.glob("*.md"))), 1)
        for i in range(tools.MAX_PENDING_REMINDERS - 1): (r / ("%016x.md" % (i + 5000))).write_text(body(datetime.now(timezone.utc) + timedelta(days=1)))
        with self.assertRaises(PermissionError): tools.call(s, u, "remind", {"text": "one too many", "when": when, "source": "claude"})   # real pending ones still count


class DeleteTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.s = Store(Path(self.d.name)); self.u = self.s.create_user("a@x.io"); self.s.grant(self.u)
        (self.s.user_vault(self.u) / "Sessions").mkdir(parents=True); (self.s.user_vault(self.u) / "Sessions" / "n.md").write_text("secret note")

    def test_failed_removal_keeps_the_account_deleting_and_a_sweep_finishes_it(self):
        with mock.patch.object(store_mod.shutil, "rmtree") as rm:                          # the disk refuses
            with self.assertRaises(DeleteIncomplete): self.s.delete_account(self.u)
        self.assertEqual(rm.call_count, 2)                                                 # retried once
        self.assertEqual(self.s.status(self.u), "deleting"); self.assertFalse(self.s.entitled(self.u)); self.assertIsNone(self.s.by_email("a@x.io"))
        self.assertTrue((self.s.user_vault(self.u) / "Sessions" / "n.md").exists())
        with mock.patch.object(store_mod.shutil, "rmtree"): self.assertEqual(self.s.finish_deletions(), [self.u])   # still failing: still listed
        self.assertEqual(self.s.finish_deletions(), []); self.assertEqual(self.s.status(self.u), "deleted")
        self.assertFalse((Path(self.d.name) / "data" / self.u).exists())

    def test_a_first_failure_that_works_on_retry_is_a_clean_delete(self):
        real, n = store_mod.shutil.rmtree, []
        def once(p, ignore_errors=False): n.append(1); return real(p, ignore_errors) if len(n) > 1 else None
        with mock.patch.object(store_mod.shutil, "rmtree", once): self.s.delete_account(self.u)
        self.assertEqual(self.s.status(self.u), "deleted")


if __name__ == "__main__": unittest.main()
