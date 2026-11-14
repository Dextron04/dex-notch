import json, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import recorder
from agentvault.adapters import default_adapters
from agentvault.adapters.notch import NotchAdapter

def line(role, text, ts, conv="c1"):
    return json.dumps({"v": 1, "conv": conv, "role": role, "text": text, "ts": ts, "model": "gemma"}) + "\n"

class NotchAdapterTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.root = Path(self.d.name) / "NotchApp"; (self.root / "journal").mkdir(parents=True)
        self.ad = NotchAdapter(self.root)
        self.f = self.root / "journal" / "11111111-aaaa.jsonl"

    def test_parse_turns_meta_and_title(self):
        self.f.write_text(line("user", "how do I rebase onto main?", "2026-11-14T10:00:00Z") + line("assistant", "git rebase main", "2026-11-14T10:00:05Z"))
        meta, turns, off = self.ad.parse(self.f, 0)
        self.assertEqual([(t.role, t.text) for t in turns], [("user", "how do I rebase onto main?"), ("assistant", "git rebase main")])
        self.assertEqual((meta.agent, meta.project, meta.session_id, meta.started), ("gemma", "notch", "11111111-aaaa", "2026-11-14T10:00:00Z"))
        self.assertEqual(meta.title, "how do I rebase onto main?")
        self.assertEqual(off, self.f.stat().st_size)

    def test_partial_last_line_waits_for_next_tick(self):
        whole = line("user", "q", "2026-11-14T10:00:00Z")
        self.f.write_text(whole + '{"v":1,"role":"assis')
        _, turns, off = self.ad.parse(self.f, 0)
        self.assertEqual(len(turns), 1); self.assertEqual(off, len(whole.encode()))

    def test_garbage_unknown_roles_and_empty_text_are_skipped(self):
        self.f.write_text("not json\n" + line("system", "x", "t") + line("user", "   ", "t") + line("user", "real", "2026-11-14T10:00:00Z"))
        _, turns, _ = self.ad.parse(self.f, 0)
        self.assertEqual([t.text for t in turns], ["real"])

    def test_resume_from_offset_has_no_title_and_only_new_turns(self):
        self.f.write_text(line("user", "q1", "2026-11-14T10:00:00Z"))
        _, _, off = self.ad.parse(self.f, 0)
        with open(self.f, "a") as fh: fh.write(line("assistant", "a1", "2026-11-14T10:00:03Z"))
        meta, turns, _ = self.ad.parse(self.f, off)
        self.assertEqual([t.text for t in turns], ["a1"]); self.assertEqual(meta.title, "")

    def test_discover_only_journal_jsonl_and_tolerates_missing_dir(self):
        (self.root / "journal" / "notes.txt").write_text("x"); self.f.write_text("")
        self.assertEqual([p.name for p in self.ad.discover()], [self.f.name])
        self.assertEqual(list(NotchAdapter(Path(self.d.name) / "nope").discover()), [])

    def test_end_to_end_note_is_redacted_idempotent_and_grows(self):
        vault = Path(self.d.name) / "Vault"
        self.f.write_text(line("user", "my key is sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA ok?", "2026-11-14T10:00:00Z") + line("assistant", "rotate it", "2026-11-14T10:00:04Z"))
        recorder.tick(vault, [self.ad], wait=True); recorder.tick(vault, [self.ad], wait=True)   # twice: no duplicates
        notes = list((vault / "Sessions" / "gemma").rglob("*.md")); self.assertEqual(len(notes), 1)
        text = notes[0].read_text()
        self.assertNotIn("sk-ant-api03-AAAA", text); self.assertEqual(text.count("rotate it"), 1)
        with open(self.f, "a") as fh: fh.write(line("user", "thanks", "2026-11-14T10:05:00Z"))
        recorder.tick(vault, [self.ad], wait=True)
        self.assertEqual(len(list((vault / "Sessions" / "gemma").rglob("*.md"))), 1)
        self.assertIn("thanks", notes[0].read_text())

    def test_registered_in_default_adapters(self):
        self.assertIn("gemma", [a.name for a in default_adapters()])

if __name__ == "__main__": unittest.main()
