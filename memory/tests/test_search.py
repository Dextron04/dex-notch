import os, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import notes, search
from agentvault.model import Turn, SessionMeta

def add(vault, sid, text, agent="claude-code", project="notch", title="t", started="2026-11-14T10:00:00Z"):
    m = SessionMeta(agent, sid, project, "/x/" + project, started, title, "/src")
    return notes.add_turns(vault, m, [Turn("user", text, started)])[0]

class SearchTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.v = Path(self._t.name)
    def tearDown(self): self._t.cleanup()

    def test_search_ranks_by_term_hits(self):
        add(self.v, "aaaaaaaaaa1", "keychain once", title="one")
        add(self.v, "bbbbbbbbbb2", "keychain keychain keychain prompt", title="three")
        add(self.v, "cccccccccc3", "nothing relevant", title="none")
        hits = search.search(self.v, "keychain prompt")
        self.assertEqual([h.title for h in hits], ["three", "one"])
        self.assertIn("keychain", hits[0].snippet.lower())
        self.assertTrue(hits[0].path.startswith("Sessions/"))

    def test_filters_by_agent_and_since(self):
        add(self.v, "aaaaaaaaaa1", "tunnel setup", agent="codex", started="2026-11-01T00:00:00Z", title="old codex")
        add(self.v, "bbbbbbbbbb2", "tunnel setup", agent="claude-code", started="2026-11-14T00:00:00Z", title="new cc")
        self.assertEqual([h.title for h in search.search(self.v, "tunnel", agent="codex")], ["old codex"])
        self.assertEqual([h.title for h in search.search(self.v, "tunnel", since="2026-11-10")], ["new cc"])

    def test_recent_orders_by_updated(self):
        add(self.v, "aaaaaaaaaa1", "x", title="a", started="2026-11-01T00:00:00Z")
        add(self.v, "bbbbbbbbbb2", "x", title="b", started="2026-11-14T00:00:00Z")
        self.assertEqual([h.title for h in search.recent(self.v, n=5)], ["b", "a"])
        self.assertEqual(len(search.recent(self.v, n=1)), 1)

    def test_ignores_conflict_files_and_recorder_dir(self):
        p = add(self.v, "aaaaaaaaaa1", "zebra", title="real")
        (p.parent / (p.stem + ".sync-conflict-20261114-XYZ.md")).write_text(p.read_text())
        (self.v / ".recorder").mkdir(); (self.v / ".recorder" / "notes.md").write_text("zebra")
        self.assertEqual([h.title for h in search.search(self.v, "zebra")], ["real"])

    def test_read_rejects_traversal_and_absolute_paths(self):
        p = add(self.v, "aaaaaaaaaa1", "hello")
        rel = p.relative_to(self.v).as_posix()
        self.assertIn("hello", search.read(self.v, rel))
        outside = Path(tempfile.mkdtemp()) / "secret.md"; outside.write_text("TOPSECRET")
        os.symlink(outside, self.v / "link.md")
        for bad in ("../../etc/passwd", "../" + self.v.name + "/../x.md", "/etc/passwd", str(outside), "link.md", "Index.txt", ".recorder/status.json"):
            with self.assertRaises(ValueError, msg=bad): search.read(self.v, bad)

class SemanticTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.v = Path(self._t.name)
    def tearDown(self): self._t.cleanup()

    def test_semantic_hits_follow_local_ones_without_duplicates(self):
        a = add(self.v, "aaaaaaaaaa1", "keychain prompt", title="local match")
        b = add(self.v, "bbbbbbbbbb2", "ACL on the item", title="meaning match")
        rel = lambda p: p.relative_to(self.v).as_posix()
        hits = search.search(self.v, "keychain", semantic=lambda q: [rel(b), rel(a), "Sessions/gone/x.md"])
        self.assertEqual([h.title for h in hits], ["local match", "meaning match"])

    def test_semantic_failure_falls_back_to_local_results(self):
        add(self.v, "aaaaaaaaaa1", "keychain prompt", title="local match")
        def down(q): raise OSError("mini unreachable")
        self.assertEqual([h.title for h in search.search(self.v, "keychain", semantic=down)], ["local match"])

    def test_semantic_respects_agent_filter(self):
        b = add(self.v, "bbbbbbbbbb2", "x", title="other agent", agent="gemini")
        hits = search.search(self.v, "zzzz", agent="codex", semantic=lambda q: [b.relative_to(self.v).as_posix()])
        self.assertEqual(hits, [])

class ReadCapTests(unittest.TestCase):
    def test_vault_read_is_capped_and_pageable(self):
        with tempfile.TemporaryDirectory() as d:
            v = Path(d)
            p = add(v, "aaaaaaaaaa1", "word " * 20000)           # ~100 KB note
            rel = p.relative_to(v).as_posix()
            first = search.read(v, rel)
            self.assertLessEqual(len(first), 20000 + 200); self.assertIn("offset=20000", first)
            second = search.read(v, rel, offset=20000, limit=500)
            self.assertLessEqual(len(second), 500 + 200); self.assertIn("offset=20500", second)
            small = add(v, "bbbbbbbbbb2", "tiny")
            self.assertNotIn("truncated", search.read(v, small.relative_to(v).as_posix()))

if __name__ == "__main__":
    unittest.main()
