"""`python3 -m agentvault import chatgpt` end to end, as a user runs it: a small export in, notes out, rerun adds nothing."""
import json, subprocess, sys, tempfile, unittest, zipfile
from pathlib import Path
MEM = Path(__file__).resolve().parents[1]

def msg(i, parent, role, text, t):
    return {"id": i, "parent": parent, "message": {"author": {"role": role}, "create_time": t, "content": {"content_type": "text", "parts": [text]}}}
EXPORT = [
    {"id": "c1", "conversation_id": "c1", "title": "Plan the Lisbon trip", "create_time": 1700000000.0, "current_node": "a1", "mapping": {
        "r": {"id": "r", "parent": None, "message": None}, "u1": msg("u1", "r", "user", "Which neighbourhood in Lisbon?", 1700000001.0),
        "a1": msg("a1", "u1", "assistant", "Alfama, my key is sk-" + "z" * 40, 1700000002.0)}},
    {"id": "c2", "conversation_id": "c2", "title": "Sourdough", "create_time": 1700100000.0, "current_node": "a2", "mapping": {
        "r": {"id": "r", "parent": None, "message": None}, "u2": msg("u2", "r", "user", "How long to proof?", 1700100001.0),
        "a2": msg("a2", "u2", "assistant", "Overnight in the fridge.", 1700100002.0)}}]

class ImportCli(unittest.TestCase):
    def run_cli(self, vault, src):
        return subprocess.run([sys.executable, "-m", "agentvault", "--vault", str(vault), "import", "chatgpt", str(src)], cwd=MEM, capture_output=True, text=True, timeout=30)

    def test_folder_and_zip_end_to_end(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); src = d / "export"; src.mkdir(); (src / "conversations.json").write_text(json.dumps(EXPORT))
            p = self.run_cli(d / "V", src)
            self.assertEqual(p.returncode, 0, p.stderr); self.assertIn("'chats': 2", p.stdout)
            notes = sorted((d / "V").glob("Sessions/chatgpt/*/*.md")); self.assertEqual(len(notes), 2)
            text = "\n".join(n.read_text() for n in notes)
            self.assertIn("Alfama", text); self.assertIn("Overnight in the fridge", text); self.assertNotIn("z" * 40, text)
            self.assertIn("'new_turns': 0", self.run_cli(d / "V", src).stdout)                      # a second run changes nothing
            z = d / "export.zip"
            with zipfile.ZipFile(z, "w") as f: f.write(src / "conversations.json", "conversations.json")
            self.assertIn("'new_turns': 0", self.run_cli(d / "V", z).stdout)                         # the same chats from the zip are not duplicated

    def test_missing_export_is_an_error_not_a_crash(self):
        with tempfile.TemporaryDirectory() as d:
            p = self.run_cli(Path(d) / "V", Path(d) / "nope")
            self.assertNotEqual(p.returncode, 0)

if __name__ == "__main__": unittest.main()
