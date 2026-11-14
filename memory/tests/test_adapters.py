import json, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.adapters.claude_code import ClaudeCodeAdapter
from agentvault.adapters.codex import CodexAdapter
from agentvault.adapters.gemini import GeminiAdapter

def jl(*objs): return "".join(json.dumps(o) + "\n" for o in objs)

# ---- real-shape builders -------------------------------------------------
def cc_user(text, ts="2026-11-14T10:00:01.000Z", **kw):
    d = {"type": "user", "isSidechain": False, "message": {"role": "user", "content": text},
         "timestamp": ts, "cwd": "/Users/x/notch", "sessionId": "S", "origin": {"kind": "human"}}; d.update(kw); return d
def cc_asst(blocks, ts="2026-11-14T10:00:05.000Z"):
    return {"type": "assistant", "isSidechain": False, "message": {"role": "assistant", "content": blocks}, "timestamp": ts, "cwd": "/Users/x/notch"}
CC_FILE = [
    cc_user("hello there"),
    cc_asst([{"type": "thinking", "thinking": "SECRET REASONING"}, {"type": "text", "text": "Hi! Checking."},
             {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls -la /tmp", "description": "list"}}]),
    {"type": "user", "isSidechain": False, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "TOOL OUTPUT BODY"}]},
     "timestamp": "2026-11-14T10:00:06.000Z", "cwd": "/Users/x/notch"},
    cc_user("injected skill text", isMeta=True),
    {"type": "ai-title", "aiTitle": "Notch setup", "sessionId": "S"},
    {"type": "api-request", "junk": True},
]

CX_FILE = [
    {"timestamp": "2026-11-04T05:28:00.826Z", "type": "session_meta", "payload": {"id": "T", "cwd": "/Users/x/auth-lock", "timestamp": "2026-11-04T05:28:00.825Z"}},
    {"timestamp": "2026-11-04T05:28:01.000Z", "type": "response_item", "payload": {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "DEV RULES"}]}},
    {"timestamp": "2026-11-04T05:28:02.000Z", "type": "response_item", "payload": {"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "# AGENTS.md instructions\n\n<INSTRUCTIONS>x</INSTRUCTIONS>"},
        {"type": "input_text", "text": "<environment_context>\n<cwd>/x</cwd>\n</environment_context>"},
        {"type": "input_text", "text": "<heartbeat>\n<automation_id>x</automation_id>\n</heartbeat>"},
        {"type": "input_text", "text": "<external_codex_apps_open_page>{\"page_id\":null}</external_codex_apps_open_page>"},
        {"type": "input_text", "text": "Host notice: some original assistant context is unavailable."},
        {"type": "input_text", "text": ">>> APPROVAL REQUEST START\nAssess the exact planned action below."},
        {"type": "input_text", "text": "{\n  \"command\": [\"/bin/zsh\"]\n}"},
        {"type": "input_text", "text": "fix the keychain prompt"}]}},
    {"timestamp": "2026-11-04T05:28:03.000Z", "type": "response_item", "payload": {"type": "reasoning", "encrypted_content": "zzz"}},
    {"timestamp": "2026-11-04T05:28:04.000Z", "type": "response_item", "payload": {"type": "function_call", "name": "exec_command", "arguments": json.dumps({"cmd": "git status"}), "call_id": "c"}},
    {"timestamp": "2026-11-04T05:28:05.000Z", "type": "response_item", "payload": {"type": "function_call_output", "call_id": "c", "output": "TOOL OUTPUT BODY"}},
    {"timestamp": "2026-11-04T05:28:06.000Z", "type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "commentary", "content": [{"type": "output_text", "text": "narration"}]}},
    {"timestamp": "2026-11-04T05:28:07.000Z", "type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "final_answer", "content": [{"type": "output_text", "text": "Done, fixed."}]}},
]

GM_FILE = [
    {"step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT", "created_at": "2026-06-04T04:15:20Z",
     "content": "<USER_REQUEST>\nfix the 502\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nActive Document: /Users/x/hr-app/docker-compose.yml (LANGUAGE_YAML)\n</ADDITIONAL_METADATA>"},
    {"step_index": 1, "source": "SYSTEM", "type": "CONVERSATION_HISTORY", "created_at": "2026-06-04T04:15:21Z", "content": "# history"},
    {"step_index": 2, "source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": "2026-06-04T04:15:30Z", "content": "Looking at nginx.", "thinking": "SECRET REASONING"},
    {"step_index": 3, "source": "MODEL", "type": "RUN_COMMAND", "created_at": "2026-06-04T04:15:40Z", "content": "Output:\nTOOL OUTPUT BODY"},
]

CASES = [
    ("claude-code", ClaudeCodeAdapter, CC_FILE, lambda r: r / "-Users-x-notch" / "S.jsonl", "S", "notch"),
    ("codex", CodexAdapter, CX_FILE, lambda r: r / "2026" / "11" / "04" / "rollout-2026-11-04T05-28-00-T.jsonl", "rollout-2026-11-04T05-28-00-T", "auth-lock"),
    ("gemini", GeminiAdapter, GM_FILE, lambda r: r / "BRAIN1" / ".system_generated" / "logs" / "transcript.jsonl", "BRAIN1", "hr-app"),
]

class TruncationTests(unittest.TestCase):
    def test_secret_at_truncation_boundary_is_redacted(self):
        from agentvault.adapters.base import tool_line, flat
        key = "sk-proj-" + "A" * 40
        self.assertNotIn("sk-proj-AAA", tool_line("Bash", {"command": "x" * 80 + " --key " + key}))
        self.assertNotIn("sk-proj-AAA", flat("a title with a key " + key + " inside", 40))

    def test_tool_line_keeps_argument_names_so_assignments_are_caught(self):
        from agentvault.adapters.base import tool_line
        self.assertNotIn("hunter2xyz99", tool_line("login", {"password": "hunter2xyz99", "user": "bob"}))

class AdapterTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory(); self.root = Path(self._t.name)
    def tearDown(self): self._t.cleanup()

    def each(self):
        for name, cls, recs, where, sid, proj in CASES:
            p = where(self.root); p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(jl(*recs)); yield name, cls(self.root), p, recs, sid, proj
            p.unlink()

    def test_discovers_files(self):
        for name, ad, p, *_ in self.each(): self.assertEqual(list(ad.discover()), [p], name)

    def test_extracts_user_and_assistant_text(self):
        expect = {"claude-code": [("user", "hello there"), ("assistant", "Hi! Checking.")],
                  "codex": [("user", "fix the keychain prompt"), ("assistant", "Done, fixed.")],
                  "gemini": [("user", "fix the 502"), ("assistant", "Looking at nginx.")]}
        for name, ad, p, *_ in self.each():
            meta, turns, off = ad.parse(p, 0)
            got = [(t.role, t.text) for t in turns if t.role != "tool"]
            self.assertEqual(got, expect[name], name)
            self.assertEqual(off, p.stat().st_size, name)

    def test_tool_use_becomes_one_line_summary(self):
        want = {"claude-code": "ran: Bash ls -la /tmp", "codex": "ran: exec_command git status", "gemini": "ran: RUN_COMMAND"}
        for name, ad, p, *_ in self.each():
            _, turns, _ = ad.parse(p, 0)
            tools = [t.text for t in turns if t.role == "tool"]
            self.assertEqual(tools, [want[name]], name)

    def test_skips_tool_output_and_reasoning(self):
        for name, ad, p, *_ in self.each():
            _, turns, _ = ad.parse(p, 0)
            blob = " ".join(t.text for t in turns)
            for bad in ("TOOL OUTPUT BODY", "SECRET REASONING", "DEV RULES", "AGENTS.md", "narration", "injected skill text", "<environment_context>", "<heartbeat>", ">>> APPROVAL", "external_codex_apps", "Host notice", "/bin/zsh"):
                self.assertNotIn(bad, blob, name + ":" + bad)

    def test_meta_has_project_cwd_title(self):
        for name, ad, p, recs, sid, proj in self.each():
            meta, turns, _ = ad.parse(p, 0)
            self.assertEqual((meta.agent, meta.session_id, meta.project, meta.source_path), (name, sid, proj, str(p)), name)
            self.assertTrue(meta.started and meta.cwd.endswith(proj), name)
            self.assertTrue(meta.title, name)
        _, ad, p, *_ = next(iter(self.each()))  # claude-code ai-title wins
        self.assertEqual(ad.parse(p, 0)[0].title, "Notch setup")

    def test_cwd_is_first_seen_not_last(self):
        p = self.root / "-Users-x-notch" / "S.jsonl"; p.parent.mkdir(parents=True)
        p.write_text(jl(cc_user("a"), dict(cc_user("b", "2026-11-14T10:00:02.000Z"), cwd="/Users/x/notch/deeper")))
        meta, _, _ = ClaudeCodeAdapter(self.root).parse(p, 0)
        self.assertEqual((meta.cwd, meta.project), ("/Users/x/notch", "notch"))

    def test_partial_last_line_not_consumed(self):
        for name, ad, p, recs, *_ in self.each():
            full = p.read_text(); cut = full.rstrip("\n")[:-5]  # last line now half-written
            p.write_text(cut)
            _, t1, off1 = ad.parse(p, 0)
            self.assertEqual(off1, len(cut[: cut.rfind("\n") + 1].encode()), name)
            p.write_text(full)
            _, t2, off2 = ad.parse(p, off1)
            self.assertEqual(off2, p.stat().st_size, name)
            _, whole, _ = ad.parse(p, 0)
            self.assertEqual([(t.role, t.text) for t in t1 + t2], [(t.role, t.text) for t in whole], name)

    def test_offset_resumes_without_duplicates(self):
        for name, ad, p, *_ in self.each():
            _, first, off = ad.parse(p, 0)
            meta, again, off2 = ad.parse(p, off)
            self.assertEqual((again, off2), ([], off), name)

    def test_tolerates_garbage_lines(self):
        for name, ad, p, recs, *_ in self.each():
            good = p.read_text(); p.write_text("not json at all\n{broken\n" + good)
            _, turns, off = ad.parse(p, 0)
            self.assertTrue(any(t.role == "user" for t in turns), name)
            self.assertEqual(off, p.stat().st_size, name)

if __name__ == "__main__":
    unittest.main()
