import sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.hosted import ingest, store as sm, tools
from agentvault.hosted.store import Store

def sess(sid="s1", text="hello pineapple"):
    return {"meta": {"agent": "claude-code", "session_id": sid, "project": "p", "cwd": "/x", "started": "2026-11-14T10:00:00Z", "title": "T " + sid},
            "turns": [{"role": "user", "text": text, "ts": "2026-11-14T10:00:00Z"}]}

class QuotaTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup); self.s = Store(Path(self.d.name))

    def test_free_is_100mb_paid_is_500mb_and_the_owner_has_no_limit(self):
        free, paid, owner = (self.s.create_user(e) for e in ("f@x.io", "p@x.io", "o@x.io"))
        self.s.grant(paid); self.s.grant(owner, sm.OWNER_PLAN)
        self.assertEqual((self.s.quota(free), self.s.quota(paid), self.s.quota(owner)), (100 << 20, 500 << 20, None))
        self.assertEqual(self.s.status(owner), "active")

    def test_a_free_account_can_use_memory_a_canceled_one_cannot(self):
        u = self.s.create_user("f@x.io"); self.assertTrue(self.s.may_use(u)); self.assertFalse(self.s.entitled(u))
        self.assertEqual(ingest.ingest(self.s, u, {"sessions": [sess("a")]})["sessions"], 1)
        tools.call(self.s, u, "remember", {"title": "t", "content": "c", "source": "claude"})
        self.s.set_status(u, "canceled"); self.assertFalse(self.s.may_use(u))
        with self.assertRaises(PermissionError): tools.call(self.s, u, "remember", {"title": "t", "content": "c", "source": "claude"})

    def test_free_limit_applies_to_free_and_not_to_the_owner(self):
        free, owner = self.s.create_user("f@x.io"), self.s.create_user("o@x.io"); self.s.grant(owner, sm.OWNER_PLAN)
        real = sm.FREE_QUOTA; self.addCleanup(setattr, sm, "FREE_QUOTA", real); sm.FREE_QUOTA = 1000
        with self.assertRaisesRegex(ingest.IngestError, "quota"): ingest.ingest(self.s, free, {"sessions": [sess("b", "x" * 10)]}, body_bytes=5000)
        self.assertEqual(ingest.ingest(self.s, owner, {"sessions": [sess("b", "x" * 10)]}, body_bytes=5000)["sessions"], 1)

    def test_losing_the_owner_plan_or_going_free_brings_the_limit_back(self):
        u = self.s.create_user("o@x.io"); self.s.grant(u, sm.OWNER_PLAN); self.assertIsNone(self.s.quota(u))
        self.s.grant(u, "placeholder"); self.assertEqual(self.s.quota(u), 500 << 20)
        self.s.set_status(u, "pending"); self.assertEqual(self.s.quota(u), 100 << 20)

if __name__ == "__main__": unittest.main()
