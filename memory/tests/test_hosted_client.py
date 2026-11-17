import json, sys, tempfile, threading, time, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import hosted_sync, notes, settings
from agentvault.__main__ import HostedLink
from agentvault.hosted import devices, tools
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store
from agentvault.model import SessionMeta, Turn

def meta(sid="aaaaaaaaaa1", title="Auth fix"): return SessionMeta("codex", sid, "auth", "/x", "2026-11-14T10:00:00Z", title, "/s")
T = lambda role, text, n: Turn(role, text, "2026-11-14T10:00:%02dZ" % n)

class ReadNoteTests(unittest.TestCase):
    def test_round_trip_including_awkward_text(self):
        with tempfile.TemporaryDirectory() as d:
            turns = [T("user", "plain", 0), T("assistant", "line one\n\n## user · 2026-01-01T00:00:00Z\n\nfake header inside a message\n\n- list", 1),
                     T("tool", "ran:   Bash   ls -la", 2), T("assistant", "", 3), T("user", "unicode ✓ 日本語", 4)]
            p, _ = notes.add_turns(Path(d), meta(), turns)
            fm, got = notes.read_note(p)
            self.assertEqual((fm["agent"], fm["session_id"], fm["title"], fm["turns"]), ("codex", "aaaaaaaaaa1", "Auth fix", 5))
            self.assertEqual([(t.role, t.ts) for t in got], [(t.role, t.ts) for t in turns])
            self.assertEqual([t.text for t in got], [t.text if t.role != "tool" else " ".join(t.text.split()) for t in turns])

class SettingsTests(unittest.TestCase):
    def test_load_hosted(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "s.json"; tok = lambda s, a: "dvt_abc" if (s, a) == (settings.HOSTED_SERVICE, settings.HOSTED_ACCOUNT) else None
            self.assertIsNone(settings.load_hosted(p, tok))                                                 # no file
            p.write_text(json.dumps({"hosted": {"host": "https://vault.example.com/"}}))
            self.assertEqual(settings.load_hosted(p, tok), {"host": "vault.example.com", "base": "https://vault.example.com", "token": "dvt_abc", "upload": True})
            p.write_text(json.dumps({"hosted": {"host": "vault.example.com", "upload": False}})); self.assertFalse(settings.load_hosted(p, tok)["upload"])   # linked, but not keeping conversations
            p.write_text(json.dumps({"hosted": {"host": "vault.example.com"}}))
            self.assertIsNone(settings.load_hosted(p, lambda s, a: None))                                   # no token in the keychain
            self.assertIsNone(settings.load_hosted(p, lambda s, a: "not-a-device-token"))
            for bad in ("evil.com/steal", "a b.com", "http://x.com", "", "x.com:99999"):
                p.write_text(json.dumps({"hosted": {"host": bad}})); self.assertIsNone(settings.load_hosted(p, tok), bad)
            p.write_text("{nope"); self.assertIsNone(settings.load_hosted(p, tok))

class PushTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.root = Path(self.d.name); self.vault = self.root / "Vault"; self.sent = []
        self.post = lambda b, t, p: self.sent.append(p) or {}

    def test_only_new_turns_go_up_and_state_survives(self):
        notes.add_turns(self.vault, meta(), [T("user", "one", 0), T("assistant", "two", 1)])
        s = hosted_sync.push(self.vault, "https://h", "dvt_x", self.post)
        self.assertEqual((s, [len(x["sessions"][0]["turns"]) for x in self.sent]), ({"sessions": 1, "turns": 2}, [2]))
        self.assertEqual(hosted_sync.push(self.vault, "https://h", "dvt_x", self.post), {"sessions": 0, "turns": 0}); self.assertEqual(len(self.sent), 1)   # nothing changed: no request
        notes.add_turns(self.vault, meta(), [T("user", "three", 2)])
        hosted_sync.push(self.vault, "https://h", "dvt_x", self.post)
        self.assertEqual([t["text"] for t in self.sent[-1]["sessions"][0]["turns"]], ["three"])                  # just the new one
        notes.add_turns(self.vault, meta(title="Renamed"), [])                                                   # late title only
        hosted_sync.push(self.vault, "https://h", "dvt_x", self.post)
        self.assertEqual((self.sent[-1]["sessions"][0]["meta"]["title"], self.sent[-1]["sessions"][0]["turns"]), ("Renamed", []))

    def test_failure_does_not_advance_state(self):
        notes.add_turns(self.vault, meta(), [T("user", "one", 0)])
        def boom(*a): raise OSError("offline")
        with self.assertRaises(OSError): hosted_sync.push(self.vault, "https://h", "dvt_x", boom)
        self.assertEqual(hosted_sync.push(self.vault, "https://h", "dvt_x", self.post)["turns"], 1)               # retried in full

    def test_big_sessions_are_chunked_and_requests_bounded(self):
        notes.add_turns(self.vault, meta("big0000001"), [T("user", "x%d" % i, i % 60) for i in range(hosted_sync.CHUNK_TURNS * 2 + 5)])
        for i in range(hosted_sync.MAX_SESSIONS + 3): notes.add_turns(self.vault, meta("s%09d" % i), [T("user", "hi", 0)])
        s = hosted_sync.push(self.vault, "https://h", "dvt_x", self.post)
        self.assertEqual(s["turns"], hosted_sync.CHUNK_TURNS * 2 + 5 + hosted_sync.MAX_SESSIONS + 3)
        self.assertTrue(all(len(x["sessions"]) <= hosted_sync.MAX_SESSIONS and len(json.dumps(x)) <= hosted_sync.MAX_REQUEST + 5000 for x in self.sent))
        self.assertTrue(all(len(it["turns"]) <= hosted_sync.CHUNK_TURNS for x in self.sent for it in x["sessions"]))

    def test_end_to_end_into_a_real_hosted_server(self):
        store = Store(self.root / "srv"); uid = store.create_user("a@x.io"); store.grant(uid); _, tok = devices.create(store, uid, "Mac")
        srv = make_server(store, Auth(store), "https://h.test", lambda e, l: None, port=0)
        threading.Thread(target=srv.serve_forever, daemon=True).start(); self.addCleanup(srv.server_close); self.addCleanup(srv.shutdown)
        base = "http://127.0.0.1:%d" % srv.server_address[1]
        notes.add_turns(self.vault, meta(), [T("user", "the code word is pineapple", 0), T("tool", "ran ls", 1)])
        self.assertEqual(hosted_sync.push(self.vault, base, tok), {"sessions": 1, "turns": 2})
        hit = json.loads(tools.call(store, uid, "vault_search", {"query": "pineapple"}))
        self.assertEqual(len(hit), 1); self.assertIn("pineapple", tools.call(store, uid, "vault_read", {"path": hit[0]["path"]}))
        devices.revoke(store, uid, devices.listing(store, uid)[0]["id"])
        notes.add_turns(self.vault, meta(), [T("user", "later", 5)])
        with self.assertRaisesRegex(hosted_sync.HostedError, "rejected"): hosted_sync.push(self.vault, base, tok)
        store.set_status(uid, "canceled"); _, tok2 = devices.create(store, uid, "Mac2")
        with self.assertRaisesRegex(hosted_sync.HostedError, "subscription"): hosted_sync.push(self.vault, base, tok2)

class LinkTests(unittest.TestCase):
    def test_follows_settings_without_a_restart(self):
        cfgs = [None]; pushes = []; started = []
        import agentvault.__main__ as m
        real = m.reminder_stream.run
        m.reminder_stream.run = lambda *a, **k: started.append((a[1:3], k["path"], k["stop"]))
        self.addCleanup(setattr, m.reminder_stream, "run", real)
        link = HostedLink(Path("/v"), load=lambda: cfgs[0], push=lambda *a: pushes.append(a) or {"sessions": 0, "turns": 0})
        link.tick(); self.assertEqual((pushes, started), ([], []))                                          # not configured: does nothing
        cfgs[0] = {"host": "h", "base": "https://h", "token": "dvt_1"}; link.tick(); time.sleep(0.1)
        self.assertEqual(len(pushes), 1); self.assertEqual((started[0][0], started[0][1]), (("https://h", "dvt_1"), "/v1/reminders/wait"))
        link.tick(); self.assertEqual(len(started), 1)                                                      # same settings: stream not restarted
        cfgs[0] = {"host": "h", "base": "https://h", "token": "dvt_2"}; link.tick(); time.sleep(0.1)
        self.assertEqual(len(started), 2); self.assertTrue(started[0][2].is_set())                          # token changed: old stream told to stop
        cfgs[0] = None; link.tick(); self.assertTrue(started[1][2].is_set()); self.assertEqual(len(pushes), 3)
        cfgs[0] = {"host": "h", "base": "https://h", "token": "dvt_2", "upload": False}; link.tick(); time.sleep(0.1)
        self.assertEqual(len(pushes), 3)                                                                    # linked but opted out: reminders still arrive, nothing is uploaded
    def test_errors_are_reported_once(self):
        import io, contextlib
        link = HostedLink(Path("/v"), load=lambda: {"host": "h", "base": "https://h", "token": "dvt_1"}, push=lambda *a: (_ for _ in ()).throw(hosted_sync.HostedError("no active subscription")))
        link.stop = None; real = threading.Thread; threading.Thread = lambda **k: type("T", (), {"start": lambda s: None})()
        self.addCleanup(setattr, threading, "Thread", real)
        err = io.StringIO()
        with contextlib.redirect_stderr(err): link.tick(); link.tick(); link.tick()
        self.assertEqual(err.getvalue().count("no active subscription"), 1)

if __name__ == "__main__": unittest.main()
