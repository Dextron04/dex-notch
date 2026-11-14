import fcntl, json, sys, tempfile, tracemalloc, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import recorder, notes
from agentvault.adapters.base import Adapter
from agentvault.adapters.claude_code import ClaudeCodeAdapter
from agentvault.model import Turn, SessionMeta

def u(text, i=1): return {"type": "user", "message": {"role": "user", "content": text}, "origin": {"kind": "human"},
                         "timestamp": "2026-11-14T10:00:%02dZ" % i, "cwd": "/Users/x/notch"}
def a(text, i=2): return {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]},
                         "timestamp": "2026-11-14T10:00:%02dZ" % i, "cwd": "/Users/x/notch"}
def jl(*o): return "".join(json.dumps(x) + "\n" for x in o)

class FakeAdapter(Adapter):
    name = "fake"
    def __init__(self, root, boom_on=None, die_on=None):
        super().__init__(root); self.boom_on, self.die_on, self.calls = boom_on, die_on, []
    def discover(self): return iter(sorted(self.root.glob("*.txt")))
    def parse(self, path, offset):
        self.calls.append(path.name)
        if path.name == self.boom_on: raise ValueError("bad file")
        if path.name == self.die_on: raise KeyboardInterrupt()
        size = path.stat().st_size
        if size <= offset: return None, [], offset
        m = SessionMeta("fake", path.stem, "proj", "/x/proj", "2026-11-14T10:00:00Z", "t " + path.stem, str(path))
        return m, [Turn("user", "hello from " + path.stem, "2026-11-14T10:00:01Z")], size

class RecorderTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.tmp = Path(self._t.name)
        self.vault, self.src = self.tmp / "Vault", self.tmp / "src"
        self.src.mkdir(); (self.src / "-Users-x-notch").mkdir()
        self.f = self.src / "-Users-x-notch" / "S1.jsonl"
    def tearDown(self): self._t.cleanup()
    def cc(self): return [ClaudeCodeAdapter(self.src)]
    def turns_in_notes(self): return sum(notes.read_frontmatter(p)["turns"] for p in self.vault.glob("Sessions/*/*/*.md"))

    def test_tick_records_new_turns_once(self):
        self.f.write_text(jl(u("q1"), a("a1")))
        self.assertEqual(recorder.tick(self.vault, self.cc())["new_turns"], 2)
        self.assertEqual(recorder.tick(self.vault, self.cc())["new_turns"], 0)
        with open(self.f, "a") as fh: fh.write(jl(u("q2", 3)))
        self.assertEqual(recorder.tick(self.vault, self.cc())["new_turns"], 1)
        self.assertEqual(self.turns_in_notes(), 3)
        self.assertTrue((self.vault / "Index.md").exists())

    def test_resumes_after_interruption(self):
        for n in "12345": (self.src / ("f%s.txt" % n)).write_text("x")
        first = FakeAdapter(self.src, die_on="f3.txt")
        with self.assertRaises(KeyboardInterrupt): recorder.tick(self.vault, [first])
        second = FakeAdapter(self.src)
        recorder.tick(self.vault, [second])
        self.assertEqual(sorted(set(second.calls)), ["f3.txt", "f4.txt", "f5.txt"])  # f1, f2 not re-parsed
        self.assertEqual(self.turns_in_notes(), 5)  # no duplicates

    def test_truncated_source_rebuilds_note(self):
        self.f.write_text(jl(u("q1"), a("a1"), u("q2", 3)))
        recorder.tick(self.vault, self.cc()); self.assertEqual(self.turns_in_notes(), 3)
        self.f.write_text(jl(u("fresh")))  # replaced by a shorter file
        recorder.tick(self.vault, self.cc())
        self.assertEqual(self.turns_in_notes(), 1)
        self.assertIn("fresh", next(self.vault.glob("Sessions/*/*/*.md")).read_text())

    def test_one_bad_file_does_not_stop_others(self):
        for n in "123": (self.src / ("f%s.txt" % n)).write_text("x")
        s = recorder.tick(self.vault, [FakeAdapter(self.src, boom_on="f2.txt")])
        self.assertEqual(self.turns_in_notes(), 2)
        self.assertEqual(len(s["errors"]), 1); self.assertIn("f2.txt", s["errors"][0])

    def test_status_json_written_with_per_agent_counts(self):
        self.f.write_text(jl(u("q1"), a("a1")))
        recorder.tick(self.vault, self.cc() + [FakeAdapter(self.tmp / "nope")])
        st = json.loads((self.vault / ".recorder" / "status.json").read_text())
        self.assertEqual(st["agents"]["claude-code"], {"sessions": 1, "turns": 2, "state": "ok"})
        self.assertEqual(st["agents"]["fake"]["state"], "unsupported")
        self.assertTrue(st["last_run"])

    def test_cwd_change_mid_session_keeps_one_note(self):
        self.f.write_text(jl(u("q1"), a("a1")))
        recorder.tick(self.vault, self.cc())
        moved = dict(u("q2", 3), cwd="/Users/x/notch/subdir")
        with open(self.f, "a") as fh: fh.write(jl(moved))
        recorder.tick(self.vault, self.cc())
        files = list(self.vault.glob("Sessions/*/*/*.md"))
        self.assertEqual(len(files), 1)
        self.assertEqual(notes.read_frontmatter(files[0])["turns"], 3)

    def test_same_session_copied_into_two_project_dirs_is_not_duplicated(self):
        (self.src / "-Users-x-other").mkdir()
        copy = self.src / "-Users-x-other" / "S1.jsonl"   # resumed-session copy: same id, longer
        self.f.write_text(jl(u("q1"), a("a1")))
        copy.write_text(jl(u("q1"), a("a1"), u("q2", 3)))
        recorder.tick(self.vault, self.cc())
        files = list(self.vault.glob("Sessions/*/*/*.md"))
        self.assertEqual(len(files), 1)
        self.assertEqual(notes.read_frontmatter(files[0])["turns"], 3)
        with open(copy, "a") as fh: fh.write(jl(a("a2", 4)))
        recorder.tick(self.vault, self.cc())
        self.assertEqual(notes.read_frontmatter(files[0])["turns"], 4)
        st = json.loads((self.vault / ".recorder" / "status.json").read_text())
        self.assertEqual(st["agents"]["claude-code"]["sessions"], 1)

    def test_failed_note_write_does_not_lose_turns(self):
        self.f.write_text(jl(u("q1"), a("a1")))
        real = recorder.add_turns
        def boom(*args, **kw): raise OSError("disk full")
        recorder.add_turns = boom
        try: s = recorder.tick(self.vault, self.cc())
        finally: recorder.add_turns = real
        self.assertEqual(len(s["errors"]), 1)
        recorder.tick(self.vault, self.cc())
        self.assertEqual(self.turns_in_notes(), 2)

    def test_state_loss_does_not_duplicate_turns(self):
        self.f.write_text(jl(u("q1"), a("a1")))
        recorder.tick(self.vault, self.cc())
        (self.vault / ".recorder" / "state.json").unlink()
        recorder.tick(self.vault, self.cc())
        self.assertEqual(self.turns_in_notes(), 2)

    def test_kill_between_note_write_and_state_save_does_not_duplicate(self):
        self.f.write_text(jl(u("q1"), a("a1")))
        real = recorder.write_atomic
        def die(path, text):
            if Path(path).name == "state.json": raise KeyboardInterrupt()
            return real(path, text)
        recorder.write_atomic = die
        try:
            with self.assertRaises(KeyboardInterrupt): recorder.tick(self.vault, self.cc())
        finally: recorder.write_atomic = real
        recorder.tick(self.vault, self.cc())
        self.assertEqual(self.turns_in_notes(), 2)

    def test_second_recorder_is_refused_while_one_is_running(self):
        (self.vault / ".recorder").mkdir(parents=True)
        self.f.write_text(jl(u("q1")))
        with open(self.vault / ".recorder" / "lock", "w") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            s = recorder.tick(self.vault, self.cc())
        self.assertTrue(s.get("skipped")); self.assertEqual(self.turns_in_notes(), 0)

    def test_corrupt_state_refuses_to_run(self):
        self.f.write_text(jl(u("q1")))
        recorder.tick(self.vault, self.cc())
        (self.vault / ".recorder" / "state.json").write_text("{not json")
        with self.assertRaises(recorder.StateError): recorder.tick(self.vault, self.cc())

    def test_truncating_one_copy_of_a_shared_session_keeps_the_union(self):
        (self.src / "-Users-x-other").mkdir()
        copy = self.src / "-Users-x-other" / "S1.jsonl"
        self.f.write_text(jl(u("q1"), a("a1")))
        copy.write_text(jl(u("q1"), a("a1"), u("q2", 3), a("a2", 4)))
        recorder.tick(self.vault, self.cc()); self.assertEqual(self.turns_in_notes(), 4)
        self.f.write_text(jl(u("q1")))   # the short copy is cut down
        recorder.tick(self.vault, self.cc()); recorder.tick(self.vault, self.cc())
        self.assertEqual(self.turns_in_notes(), 4)

    def test_header_only_first_poll_does_not_pin_session_identity(self):
        header = {"type": "mode", "mode": "auto"}   # real files start with records that carry no cwd or timestamp
        self.f.write_text(jl(header, {"type": "permission-mode", "permissionMode": "auto"}))
        recorder.tick(self.vault, self.cc())
        with open(self.f, "a") as fh: fh.write(jl(u("q1"), a("a1")))
        recorder.tick(self.vault, self.cc())
        (note,) = list(self.vault.glob("Sessions/*/*/*.md"))
        self.assertEqual(note.parent.name, "2026-11"); self.assertIn("notch", note.name)

    def test_large_file_streamed(self):
        blob = "x" * 50_000
        with open(self.f, "w") as fh:
            fh.write(jl(u("start")))
            for i in range(1000):  # ~50MB of tool results that must never be held in memory
                fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": blob}]}}) + "\n")
            fh.write(jl(a("end", 9)))
        tracemalloc.start()
        s = recorder.tick(self.vault, self.cc())
        peak = tracemalloc.get_traced_memory()[1]; tracemalloc.stop()
        self.assertEqual(s["new_turns"], 2)
        self.assertLess(peak, 100 * 1024 * 1024)

if __name__ == "__main__":
    unittest.main()
