import json, os, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import notes
from agentvault.model import Turn, SessionMeta
from agentvault.hosted.store import Store
from agentvault.hosted import tools

def save(vault, sid, text):
    notes.append_turns(vault, SessionMeta("codex", sid, "p", "/x", "2026-11-14T10:00:00Z", "t " + sid, "/s"), [Turn("user", text, "2026-11-14T10:00:00Z")])

class HostedTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.s = Store(Path(self.d.name))
        self.a, self.b = self.s.create_user("A@x.io"), self.s.create_user("b@x.io")
        for u in (self.a, self.b): self.s.grant(u)
        save(self.s.user_vault(self.a), "aaaaaaaaaa1", "alpha secret plan")
        save(self.s.user_vault(self.b), "bbbbbbbbbb1", "beta secret plan")

    def paths(self, uid, q="secret"): return [h["path"] for h in json.loads(tools.call(self.s, uid, "vault_search", {"query": q}))]

    def test_users(self):
        self.assertTrue(self.a.startswith("u_") and self.a != self.b)
        self.assertEqual(self.s.by_email(" a@X.io "), self.a)
        with self.assertRaises(ValueError): self.s.create_user("a@x.io")
        with self.assertRaises(ValueError): self.s.create_user("nope")

    def test_search_and_recent_see_only_own_notes(self):
        for uid, mine in ((self.a, "aaaaaaaaaa1"), (self.b, "bbbbbbbbbb1")):
            got = self.paths(uid); self.assertEqual(len(got), 1); self.assertIn(mine[-10:], got[0])
            rec = [h["path"] for h in json.loads(tools.call(self.s, uid, "vault_recent", {}))]
            self.assertEqual(rec, got)

    def test_read_cannot_reach_other_user(self):
        theirs = self.paths(self.b)[0]
        for rel in (theirs, "../../%s/Vault/%s" % (self.b, theirs), "../../../hosted.db"):
            with self.assertRaises(Exception): tools.call(self.s, self.a, "vault_read", {"path": rel})
        self.assertIn("beta secret", tools.call(self.s, self.b, "vault_read", {"path": theirs}))

    def test_symlinks_out_of_vault_are_not_followed(self):
        va, theirs = self.s.user_vault(self.a), self.s.user_vault(self.b) / self.paths(self.b)[0]
        month = va / "Sessions" / "codex" / "2026-11"
        os.symlink(theirs, month / "stolen.md")                                  # note symlink
        os.symlink(self.s.user_vault(self.b) / "Sessions" / "codex", va / "Sessions" / "evil")  # folder symlink
        self.assertEqual(len(self.paths(self.a)), 1)
        self.assertEqual(len(json.loads(tools.call(self.s, self.a, "vault_recent", {"n": 10}))), 1)
        with self.assertRaises(Exception): tools.call(self.s, self.a, "vault_read", {"path": "Sessions/codex/2026-11/stolen.md"})

    def test_writes_land_in_own_vault(self):
        tools.call(self.s, self.a, "remember", {"title": "n", "content": "gamma only for a", "source": "claude"})
        self.assertEqual(len(self.paths(self.a, "gamma")), 1); self.assertEqual(self.paths(self.b, "gamma"), [])

    def test_bad_ids_and_unpaid_users(self):
        for bad in ("", "../x", "u_short", self.a + "/..", "u_" + "A" * 22):
            with self.assertRaises((ValueError, KeyError, PermissionError)): tools.call(self.s, bad, "vault_recent", {})
        c = self.s.create_user("c@x.io")                                         # pending: not paid yet
        with self.assertRaises(PermissionError): tools.call(self.s, c, "vault_recent", {})
        self.assertFalse((Path(self.d.name) / "data" / c).exists())               # refused before any directory exists
        self.s.grant(c); self.assertEqual(json.loads(tools.call(self.s, c, "vault_recent", {})), [])
        for st in ("canceled", "deleted"):
            self.s.set_status(c, st)
            with self.assertRaises(PermissionError): tools.call(self.s, c, "vault_recent", {})
        self.s.set_status(c, "past_due"); tools.call(self.s, c, "vault_recent", {})
        with self.assertRaises(ValueError): self.s.set_status(c, "vip")

if __name__ == "__main__": unittest.main()
