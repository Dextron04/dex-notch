import sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.model import Turn, SessionMeta
from agentvault import notes, index

def meta(sid="aaaaaaaa-1111", project="notch", agent="claude-code", title="Fix hotkey", started="2026-11-14T10:00:00Z"):
    return SessionMeta(agent=agent, session_id=sid, project=project, cwd="/Users/x/" + project,
                       started=started, title=title, source_path="/tmp/src.jsonl")

class NotesTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.vault = Path(self._t.name)
    def tearDown(self): self._t.cleanup()

    def test_creates_note_with_frontmatter(self):
        p = notes.append_turns(self.vault, meta(), [Turn("user", "hi", "2026-11-14T10:00:01Z")])
        self.assertTrue(p.is_relative_to(self.vault / "Sessions" / "claude-code" / "2026-11"))
        fm = notes.read_frontmatter(p)
        self.assertEqual(fm["agent"], "claude-code"); self.assertEqual(fm["project"], "notch")
        self.assertEqual(fm["session_id"], "aaaaaaaa-1111"); self.assertEqual(fm["turns"], 1)
        self.assertEqual(fm["title"], "Fix hotkey")
        self.assertIn("## user · 2026-11-14T10:00:01Z", p.read_text())

    def test_append_is_additive_and_updates_counts(self):
        m = meta()
        p = notes.append_turns(self.vault, m, [Turn("user", "q1", "2026-11-14T10:00:01Z")])
        p2 = notes.append_turns(self.vault, m, [Turn("assistant", "a1", "2026-11-14T10:00:09Z"),
                                                Turn("tool", "ran: Bash ls", "2026-11-14T10:00:10Z")])
        self.assertEqual(p, p2)
        fm = notes.read_frontmatter(p); body = p.read_text()
        self.assertEqual(fm["turns"], 3); self.assertEqual(fm["updated"], "2026-11-14T10:00:10Z")
        self.assertLess(body.index("q1"), body.index("a1"))

    def test_redacts_on_write(self):
        secret = "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        p = notes.append_turns(self.vault, meta(title="key " + secret), [Turn("user", "my " + secret, "2026-11-14T10:00:01Z")])
        self.assertNotIn(secret, p.read_text())

    def test_slug_safe_for_emoji_and_slashes(self):
        p = notes.append_turns(self.vault, meta(project="my/proj 🚀 ünï"), [Turn("user", "x", "2026-11-14T10:00:01Z")])
        self.assertTrue(p.exists()); self.assertEqual(p.parent, self.vault / "Sessions" / "claude-code" / "2026-11")
        self.assertRegex(p.name, r"^[a-z0-9\-\.]+\.md$")

    def test_same_slug_same_day_gets_unique_files(self):
        a = notes.note_path(self.vault, meta(sid="aaaaaaaa-1111"))
        b = notes.note_path(self.vault, meta(sid="bbbbbbbb-2222"))
        self.assertNotEqual(a, b)
        self.assertEqual(a, notes.note_path(self.vault, meta(sid="aaaaaaaa-1111", title="renamed later")))

    def test_long_ids_with_shared_prefix_get_unique_files(self):
        # codex session ids are filenames: rollout-<timestamp>-<uuid>
        a = notes.note_path(self.vault, meta(sid="rollout-2026-11-04T05-28-00-01a14055-e6d2-76b3-8950-74be3e38940b"))
        b = notes.note_path(self.vault, meta(sid="rollout-2026-11-04T05-28-00-01a1a1da-19f3-70e2-a36b-37ea78ac5d19"))
        self.assertNotEqual(a, b)

    def test_atomic_write_leaves_no_temp_files(self):
        p = notes.append_turns(self.vault, meta(), [Turn("user", "x", "2026-11-14T10:00:01Z")])
        self.assertEqual([f.name for f in p.parent.iterdir()], [p.name])

    def test_appending_same_turns_again_adds_nothing(self):
        m = meta(); t = [Turn("user", "q1", "2026-11-14T10:00:01Z"), Turn("tool", "ran: Bash ls", "2026-11-14T10:00:02Z")]
        p, n1 = notes.add_turns(self.vault, m, t)
        p, n2 = notes.add_turns(self.vault, m, t + [Turn("assistant", "a1", "2026-11-14T10:00:03Z")])
        self.assertEqual((n1, n2), (2, 1)); self.assertEqual(notes.read_frontmatter(p)["turns"], 3)
        self.assertEqual(p.read_text().count("q1"), 1)  # the repeated turn was not written twice

    def test_note_links_to_project_day_and_agent_hubs(self):
        p = notes.append_turns(self.vault, meta(project="My Proj"), [Turn("user", "hi", "2026-11-14T10:00:01Z")])
        t = p.read_text()
        for link in ("[[Projects/my-proj|My Proj]]", "[[Days/2026-11-14]]", "[[Agents/claude-code]]"): self.assertIn(link, t)
        self.assertLess(t.index("# Fix hotkey"), t.index("[[Projects/"))

    def test_hub_notes_for_projects_and_days(self):
        notes.append_turns(self.vault, meta(sid="aaaaaaaaaa1", title="First", started="2026-11-13T09:00:00Z"), [Turn("user", "x", "2026-11-13T09:00:01Z")])
        p2 = notes.append_turns(self.vault, meta(sid="bbbbbbbbbb2", title="Second", started="2026-11-14T09:00:00Z"), [Turn("user", "x", "2026-11-14T09:00:01Z")])
        (p2.parent / (p2.stem + ".sync-conflict-20261114-XYZ.md")).write_text(p2.read_text().replace("Second", "CONFLICT"))
        index.rebuild_indexes(self.vault)
        proj = (self.vault / "Projects" / "notch.md").read_text()
        self.assertIn("First", proj); self.assertIn("Second", proj); self.assertNotIn("CONFLICT", proj)
        self.assertLess(proj.index("Second"), proj.index("First"))
        day = (self.vault / "Days" / "2026-11-14.md").read_text()
        self.assertIn("Second", day); self.assertNotIn("First", day)
        index.rebuild_indexes(self.vault)  # idempotent
        self.assertEqual((self.vault / "Days" / "2026-11-14.md").read_text(), day)

    def test_reset_note_deletes(self):
        m = meta(); p = notes.append_turns(self.vault, m, [Turn("user", "x", "2026-11-14T10:00:01Z")])
        notes.reset_note(self.vault, m); self.assertFalse(p.exists())

    def test_indexes_list_newest_first_and_skip_conflicts(self):
        notes.append_turns(self.vault, meta(sid="aaaaaaaa-1", title="Older"), [Turn("user", "x", "2026-11-14T10:00:01Z")])
        notes.append_turns(self.vault, meta(sid="bbbbbbbb-2", title="Newer", agent="codex"), [Turn("user", "x", "2026-11-14T12:00:01Z")])
        d = self.vault / "Sessions" / "codex" / "2026-11"
        (d / "2026-11-14-notch-bbbbbbbb.sync-conflict-20261114-abc.md").write_text("---\nagent: \"codex\"\nupdated: \"2027-01-01T00:00:00Z\"\ntitle: \"CONFLICT\"\n---\n")
        index.rebuild_indexes(self.vault)
        idx = (self.vault / "Index.md").read_text()
        self.assertLess(idx.index("Newer"), idx.index("Older")); self.assertNotIn("CONFLICT", idx)
        self.assertIn("Older", (self.vault / "Agents" / "claude-code.md").read_text())
        self.assertNotIn("Older", (self.vault / "Agents" / "codex.md").read_text())

if __name__ == "__main__":
    unittest.main()
