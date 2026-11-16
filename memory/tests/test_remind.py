import json, sys, tempfile, unittest
from datetime import datetime, timezone
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.remote.tools import remind

NOW = datetime(2026, 11, 16, 12, 0, tzinfo=timezone.utc)

class RemindTests(unittest.TestCase):
    def setUp(self): self._t = tempfile.TemporaryDirectory(); self.v = Path(self._t.name)
    def tearDown(self): self._t.cleanup()
    def r(self, **kw):
        a = {"text": "call mum", "when": "2026-11-16T09:00:00-06:00", "source": "chatgpt"}; a.update(kw)
        return remind(self.v, a, now=NOW)
    def test_writes_utc_file_once(self):
        self.r(); self.r()
        fs = list((self.v / "Reminders").glob("*.md")); self.assertEqual(len(fs), 1)
        fm = dict(l.split(": ", 1) for l in fs[0].read_text().split("---")[1].strip().splitlines())
        self.assertEqual(json.loads(fm["due"]), "2026-11-16T15:00:00Z"); self.assertEqual(json.loads(fm["source"]), "chatgpt")
    def test_rejects_bad_input(self):
        for kw in ({"when": "2026-11-16T09:00:00"}, {"when": "tomorrow"}, {"when": "2020-01-01T00:00:00Z"}, {"when": "2030-01-01T00:00:00Z"},
                   {"text": ""}, {"text": "x" * 501}, {"source": "bing"}):
            with self.assertRaises(ValueError, msg=str(kw)): self.r(**kw)
    def test_redacts(self):
        self.r(text="use key sk-" + "a" * 40)
        self.assertNotIn("a" * 40, next((self.v / "Reminders").glob("*.md")).read_text())
if __name__ == "__main__": unittest.main()
