import json, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import notes, rag_push
from agentvault.model import Turn, SessionMeta

def add(v, sid, turns, title="Auth fix", project="auth", agent="codex", started="2026-11-14T10:00:00Z"):
    m = SessionMeta(agent, sid, project, "/x/" + project, started, title, "/s")
    return notes.append_turns(v, m, [Turn(r, t, "2026-11-14T10:%02d:00Z" % i) for i, (r, t) in enumerate(turns)])

class RagPushTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.v = Path(self._t.name)
        self.sent = []
        self.state = self.v / ".recorder" / "rag_state.json"
    def tearDown(self): self._t.cleanup()
    def post(self, payload): self.sent.append(payload); return {"added": len(payload["documents"]), "updated": 0, "unchanged": 0, "removed": 0}

    def test_doc_has_context_header_and_no_tool_lines_or_markers(self):
        add(self.v, "aaaaaaaaaa1", [("user", "why the keychain prompt"), ("tool", "ran: Bash ls"), ("assistant", "ACL on the item")])
        (d,) = rag_push.build_docs(self.v)
        self.assertEqual(d["title"], "Auth fix")
        self.assertTrue(d["source"].startswith("vault:Sessions/codex/"))
        self.assertIn("agent: codex", d["text"]); self.assertIn("project: auth", d["text"])
        self.assertIn("why the keychain prompt", d["text"]); self.assertIn("ACL on the item", d["text"])
        self.assertNotIn("ran: Bash", d["text"]); self.assertNotIn("<!-- t:", d["text"]); self.assertNotIn("[[Projects/", d["text"])

    def test_big_note_is_split_into_parts_under_the_limit(self):
        add(self.v, "aaaaaaaaaa1", [("user", "para %d. " % i + "word " * 200) for i in range(400)])
        docs = rag_push.build_docs(self.v)
        self.assertGreater(len(docs), 1)
        self.assertTrue(all(len(d["text"].encode()) <= rag_push.MAX_DOC_BYTES + 2000 for d in docs))
        self.assertEqual(len({d["id"] for d in docs}), len(docs)); self.assertIn("part 2", docs[1]["title"])

    def test_sync_pushes_only_changed_docs_in_small_batches(self):
        for i in range(30): add(self.v, "id%09d" % i, [("user", "topic %d " % i + "x " * 5000)], title="n%d" % i)
        r1 = rag_push.sync(self.v, post=self.post, state_path=self.state, batch_bytes=60_000)
        self.assertEqual(r1["pushed"], 30); self.assertGreater(len(self.sent), 1)
        self.assertTrue(all(p["machine"] == "vault" and p["complete"] is False for p in self.sent))
        self.assertTrue(all(len(json.dumps(p)) < 60_000 + 25_000 for p in self.sent))
        self.sent.clear()
        self.assertEqual(rag_push.sync(self.v, post=self.post, state_path=self.state)["pushed"], 0); self.assertEqual(self.sent, [])
        add(self.v, "id000000003", [("assistant", "a new answer")], title="n3")
        r3 = rag_push.sync(self.v, post=self.post, state_path=self.state)
        self.assertEqual(r3["pushed"], 1); self.assertEqual(len(self.sent), 1)

    def test_failed_batch_is_retried_and_earlier_batches_are_remembered(self):
        for i in range(6): add(self.v, "id%09d" % i, [("user", "t%d " % i + "x " * 5000)], title="n%d" % i)
        calls = []
        def flaky(payload):
            calls.append(1)
            if len(calls) == 2: raise rag_push.PushError("boom")
            return self.post(payload)
        with self.assertRaises(rag_push.PushError): rag_push.sync(self.v, post=flaky, state_path=self.state, batch_bytes=15_000)
        done = len(self.sent); self.assertGreaterEqual(done, 1)
        self.sent.clear()
        r = rag_push.sync(self.v, post=self.post, state_path=self.state, batch_bytes=15_000)
        self.assertEqual(r["pushed"] + r["skipped"], 6)
        self.assertGreater(r["skipped"], 0)

    def test_conflict_files_are_not_pushed(self):
        p = add(self.v, "aaaaaaaaaa1", [("user", "real")])
        (p.parent / (p.stem + ".sync-conflict-20261114-XYZ.md")).write_text(p.read_text())
        self.assertEqual(len(rag_push.build_docs(self.v)), 1)

if __name__ == "__main__":
    unittest.main()
