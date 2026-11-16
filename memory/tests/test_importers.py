import json, sys, tempfile, unittest, zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import importers, notes

def node(i, parent, role, parts, ct="text", t=1700000000.0):
    return {"id": i, "parent": parent, "message": {"author": {"role": role}, "create_time": t, "content": {"content_type": ct, "parts": parts}}}
CONV = {"id": "c1", "conversation_id": "c1", "title": "Trip", "create_time": 1700000000.0, "current_node": "a2", "mapping": {
    "r": {"id": "r", "parent": None, "message": None},
    "u1": node("u1", "r", "user", ["hi"]), "a1": node("a1", "u1", "assistant", ["old branch"]),
    "a2": node("a2", "u1", "assistant", ["final ", ]), "x": node("x", "a2", "system", ["sys"]),
    "th": node("th", "u1", "assistant", [], ct="thoughts")}}
CONV["mapping"]["a2"]["message"]["content"]["parts"] = ["use key sk-" + "a" * 40, {"content_type": "image_asset_pointer"}]

class ImportTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.tmp = Path(self._t.name)
        self.src = self.tmp / "exp"; self.src.mkdir()
        (self.src / "conversations-000.json").write_text(json.dumps([CONV]))
    def tearDown(self): self._t.cleanup()
    def test_branch_redaction_and_idempotence(self):
        v = self.tmp / "V"
        s = importers.import_chatgpt(v, self.src)
        self.assertEqual((s["chats"], s["new_turns"], s["errors"]), (1, 2, []))
        text = next(v.glob("Sessions/chatgpt/*/*.md")).read_text()
        self.assertIn("hi", text); self.assertNotIn("old branch", text); self.assertNotIn("sys", text.split("---", 2)[2].replace("system", ""))
        self.assertNotIn("a" * 40, text); self.assertIn("[image]", text)
        self.assertEqual(importers.import_chatgpt(v, self.src)["new_turns"], 0)
    def test_zip(self):
        z = self.tmp / "e.zip"
        with zipfile.ZipFile(z, "w") as f: f.write(self.src / "conversations-000.json", "conversations-000.json")
        self.assertEqual(importers.import_chatgpt(self.tmp / "V2", z)["chats"], 1)
if __name__ == "__main__": unittest.main()
