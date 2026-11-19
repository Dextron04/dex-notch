import json, sys, tempfile, threading, time, unittest, urllib.error, urllib.parse, urllib.request
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from datetime import datetime, timedelta, timezone
from unittest import mock
from agentvault import seal
from agentvault.hosted import devices, ingest, store as store_mod, tools
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store

NR = type("NR", (urllib.request.HTTPRedirectHandler,), {"redirect_request": lambda self, *a, **k: None})
OPENER = urllib.request.build_opener(NR)
def call(method, url, body=None, headers=None, form=False, raw=None):
    data = raw if raw is not None else (None if body is None else (urllib.parse.urlencode(body).encode() if form else json.dumps(body).encode()))
    try: r = OPENER.open(urllib.request.Request(url, data=data, method=method, headers=headers or {}), timeout=10); return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read().decode()
    except urllib.error.HTTPError as e: b = e.read().decode(); e.close(); return e.code, {k.lower(): v for k, v in e.headers.items()}, b

def sess(sid="s1", turns=None, agent="claude-code"):
    return {"meta": {"agent": agent, "session_id": sid, "project": "p", "cwd": "/x", "started": "2026-11-14T10:00:00Z", "title": "T " + sid},
            "turns": turns if turns is not None else [{"role": "user", "text": "hello pineapple", "ts": "2026-11-14T10:00:00Z"}]}

class DeviceTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.s = Store(Path(self.d.name)); self.u = self.s.create_user("a@x.io"); self.s.grant(self.u)

    def test_tokens(self):
        did, tok = devices.create(self.s, self.u, "  My   MacBook ")
        self.assertTrue(tok.startswith("dvt_")); self.assertEqual(devices.check(self.s, tok), (self.u, did))
        self.assertEqual(devices.listing(self.s, self.u)[0]["name"], "My MacBook")
        for bad in ("", "dvt_nope", tok[:-1], "Bearer " + tok, None): self.assertIsNone(devices.check(self.s, bad))
        self.assertIsNone(devices.check(self.s, "x" + tok[1:]))                  # wrong prefix
        with self.s.conn() as c: self.assertNotIn(tok, str(c.execute("SELECT * FROM devices").fetchall()))   # only the hash is stored
        other = self.s.create_user("b@x.io")
        self.assertFalse(devices.revoke(self.s, other, did)); self.assertIsNotNone(devices.check(self.s, tok))   # can't revoke someone else's
        self.assertTrue(devices.revoke(self.s, self.u, did)); self.assertIsNone(devices.check(self.s, tok))

    def test_limit(self):
        for i in range(devices.MAX_DEVICES): devices.create(self.s, self.u, "m%d" % i)
        with self.assertRaises(ValueError): devices.create(self.s, self.u, "one more")

class IngestTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.s = Store(Path(self.d.name)); self.u = self.s.create_user("a@x.io"); self.s.grant(self.u)

    def test_ingest_is_idempotent_redacted_and_searchable(self):
        secret = "sk-ant-api03-" + "A" * 40
        p = {"sessions": [sess(turns=[{"role": "user", "text": "key is " + secret, "ts": "2026-11-14T10:00:00Z"}, {"role": "tool", "text": "ran ls", "ts": "2026-11-14T10:00:01Z"}])]}
        self.assertEqual(ingest.ingest(self.s, self.u, p), {"sessions": 1, "new_turns": 2})
        self.assertEqual(ingest.ingest(self.s, self.u, p), {"sessions": 1, "new_turns": 0})              # same upload again changes nothing
        note = tools.call(self.s, self.u, "vault_read", {"path": json.loads(tools.call(self.s, self.u, "vault_recent", {}))[0]["path"]})
        self.assertNotIn(secret, note); self.assertIn("ran ls", note)

    def test_validation_writes_nothing(self):
        good = sess("good")
        bad = [{"sessions": []}, {"sessions": "x"}, [], {"sessions": [good, {"meta": {}, "turns": []}]},
               {"sessions": [good, sess("b", agent="../etc")]}, {"sessions": [good, sess("b", agent="UPPER")]},
               {"sessions": [good, sess("b", turns=[{"role": "system", "text": "x", "ts": "2026-11-14T10:00:00Z"}])]},
               {"sessions": [good, sess("b", turns=[{"role": "user", "text": "x", "ts": "yesterday"}])]},
               {"sessions": [good, sess("b", turns=[{"role": "user", "text": "x" * 200_001, "ts": "2026-11-14T10:00:00Z"}])]},
               {"sessions": [good, {"meta": dict(sess()["meta"], session_id=""), "turns": []}]},
               {"sessions": [good, {"meta": dict(sess()["meta"], started="2026-11-14"), "turns": []}]}]
        for b in bad:
            with self.assertRaises(ingest.IngestError, msg=str(b)[:80]): ingest.ingest(self.s, self.u, b)
        self.assertEqual(json.loads(tools.call(self.s, self.u, "vault_recent", {})), [])

    def test_path_tricks_stay_inside_the_vault(self):
        ingest.ingest(self.s, self.u, {"sessions": [dict(sess(), meta=dict(sess()["meta"], project="../../../../etc", session_id="../../x"))]})
        root = Path(self.d.name)
        self.assertTrue(all(str(p).startswith(str(root / "data" / self.u)) or p == root / "hosted.db" or "hosted.db" in p.name for p in root.rglob("*") if p.is_file()))

    def test_quota(self):
        real, store_mod.PAID_QUOTA = store_mod.PAID_QUOTA, 1000
        self.addCleanup(setattr, store_mod, "PAID_QUOTA", real)
        ingest.ingest(self.s, self.u, {"sessions": [sess("a")]})
        with self.assertRaisesRegex(ingest.IngestError, "quota"): ingest.ingest(self.s, self.u, {"sessions": [sess("b", [{"role": "user", "text": "x" * 5000, "ts": "2026-11-14T10:00:00Z"}])]}, body_bytes=5000)

class ServerTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail, self.t = Store(Path(self.d.name)), [], [1_000.0]
        self.srv = make_server(self.store, Auth(self.store, now=lambda: self.t[0]), "https://h.test", lambda e, l: self.mail.append((e, l)), port=0, now=lambda: self.t[0], wait_seconds=0.6)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def sign_in(self, email):
        call("POST", self.base + "/login", {"email": email}, form=True)
        st, h, _ = call("POST", self.base + "/login/verify", {"t": self.mail[-1][1].split("t=")[1]}, form=True)
        self.assertEqual((st, h["location"]), (302, "/login/done")); return {"Cookie": h["set-cookie"].split(";")[0]}

    def new_token(self, ck, name="Test Mac"):
        st, _, body = call("POST", self.base + "/account/devices", {"name": name}, ck, form=True)
        self.assertEqual(st, 200); return __import__("re").search(r"dvt_[A-Za-z0-9_-]+", body).group(0)

    def up(self, tok, payload): return call("POST", self.base + "/v1/ingest", payload, {"Authorization": "Bearer " + tok, "Content-Type": "application/json"})

    def test_account_flow_upload_and_isolation(self):
        ck = self.sign_in("a@x.io"); uid = self.store.by_email("a@x.io")
        self.assertIn("Your Macs", call("GET", self.base + "/account", headers=ck)[2])
        self.assertEqual(call("GET", self.base + "/account")[1]["location"], "/login")
        tok = self.new_token(ck)
        self.store.set_status(uid, "canceled"); self.assertEqual(self.up(tok, {"sessions": [sess()]})[0], 402)   # a free account uploads; a canceled one does not
        self.store.grant(uid)
        st, _, body = self.up(tok, {"sessions": [sess()]}); self.assertEqual((st, json.loads(body)), (200, {"sessions": 1, "new_turns": 1}))
        self.assertIn("pineapple", tools.call(self.store, uid, "vault_search", {"query": "pineapple"}))
        ck2 = self.sign_in("b@x.io"); uid2 = self.store.by_email("b@x.io"); self.store.grant(uid2); tok2 = self.new_token(ck2)
        self.up(tok2, {"sessions": [sess("other", [{"role": "user", "text": "banana", "ts": "2026-11-14T10:00:00Z"}])]})
        self.assertEqual(json.loads(tools.call(self.store, uid2, "vault_search", {"query": "pineapple"})), [])    # tenants stay apart
        self.assertEqual(json.loads(tools.call(self.store, uid, "vault_search", {"query": "banana"})), [])

    def test_bad_requests(self):
        ck = self.sign_in("a@x.io"); self.store.grant(self.store.by_email("a@x.io")); tok = self.new_token(ck)
        for h in ({}, {"Authorization": "Bearer nope"}, {"Authorization": "Bearer dvt_" + "x" * 43}):
            self.assertEqual(call("POST", self.base + "/v1/ingest", raw=b"{}", headers=h)[0], 401)
        self.assertEqual(self.up(tok, {"sessions": []})[0], 400)
        self.assertEqual(call("POST", self.base + "/v1/ingest", raw=b"not json", headers={"Authorization": "Bearer " + tok})[0], 400)
        # an OAuth access token (ChatGPT/Claude's) is not a device token, and the reverse
        self.assertEqual(call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "ping"}, {"Authorization": "Bearer " + tok, "Content-Type": "application/json"})[0], 401)

    def test_revoke_signout_and_entitlement_loss(self):
        ck = self.sign_in("a@x.io"); uid = self.store.by_email("a@x.io"); self.store.grant(uid); tok = self.new_token(ck)
        self.assertEqual(self.up(tok, {"sessions": [sess()]})[0], 200)
        self.store.set_status(uid, "canceled"); self.assertEqual(self.up(tok, {"sessions": [sess()]})[0], 402); self.store.grant(uid)
        did = devices.listing(self.store, uid)[0]["id"]
        self.assertEqual(call("POST", self.base + "/account/devices/revoke", {"id": did}, ck, form=True)[0], 302)
        self.assertEqual(self.up(tok, {"sessions": [sess()]})[0], 401)
        tok2 = self.new_token(ck)
        self.assertEqual(call("POST", self.base + "/logout", {}, ck, form=True)[0], 302)
        self.assertEqual(call("GET", self.base + "/account", headers=ck)[1]["location"], "/login")   # session is gone
        self.assertEqual(self.up(tok2, {"sessions": [sess()]})[0], 200)                                # the Mac's token is not
        ck = self.sign_in("a@x.io"); call("POST", self.base + "/account/signout-all", {}, ck, form=True)
        self.assertEqual(call("GET", self.base + "/account", headers=ck)[1]["location"], "/login")

    def test_rate_limit(self):
        ck = self.sign_in("a@x.io"); self.store.grant(self.store.by_email("a@x.io")); tok = self.new_token(ck)
        codes = [call("GET", self.base + "/v1/reminders/wait?after=", headers={"Authorization": "Bearer " + tok})[0] for _ in range(125)]
        self.assertEqual((codes.count(200), codes.count(429)), (120, 5))

    def test_reminders_wait(self):
        ck = self.sign_in("a@x.io"); uid = self.store.by_email("a@x.io"); self.store.grant(uid); tok = self.new_token(ck); H = {"Authorization": "Bearer " + tok}
        self.assertEqual(call("GET", self.base + "/v1/reminders/wait")[0], 401)
        t0 = time.monotonic(); st, _, b = call("GET", self.base + "/v1/reminders/wait?after=", headers=H); d = json.loads(b)
        self.assertEqual((st, d["files"]), (200, []))                                                    # first call answers at once with nothing set
        from datetime import datetime, timedelta, timezone
        when = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
        res = {}
        th = threading.Thread(target=lambda: res.update(r=json.loads(call("GET", self.base + "/v1/reminders/wait?after=" + urllib.parse.quote(d["token"]), headers=H)[2]))); th.start()
        time.sleep(0.2); tools.call(self.store, uid, "remind", {"text": "call mum", "when": when, "source": "claude"}); th.join(5)
        self.assertEqual([f["name"][-3:] for f in res["r"]["files"]], [".md"]); self.assertIn("call mum", res["r"]["files"][0]["content"])
        other = self.sign_in("b@x.io"); self.store.grant(self.store.by_email("b@x.io")); tok2 = self.new_token(other)
        self.assertEqual(json.loads(call("GET", self.base + "/v1/reminders/wait?after=", headers={"Authorization": "Bearer " + tok2})[2])["files"], [])   # not their reminder

    def test_an_unreadable_reminder_is_not_skipped_past(self):
        ck = self.sign_in("a@x.io"); uid = self.store.by_email("a@x.io"); tok = self.new_token(ck); H = {"Authorization": "Bearer " + tok}
        when = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
        for t in ("first", "second", "third"): tools.call(self.store, uid, "remind", {"text": t, "when": when, "source": "claude"}); time.sleep(0.01)
        files = sorted((self.store.user_vault(uid) / "Reminders").glob("*.md"), key=lambda p: p.stat().st_mtime_ns); bad = files[1].name
        real = seal.read_text
        def flaky(p, *a, **k):
            if Path(p).name == bad: raise OSError("disk hiccup")
            return real(p, *a, **k)
        with mock.patch("agentvault.hosted.server.seal.read_text", flaky):
            d = json.loads(call("GET", self.base + "/v1/reminders/wait?after=", headers=H)[2])
            self.assertEqual([f["name"] for f in d["files"]], [files[0].name])             # what came before it, and no more
            d2 = json.loads(call("GET", self.base + "/v1/reminders/wait?after=" + urllib.parse.quote(d["token"]), headers=H)[2])
            self.assertEqual(d2["files"], [])                                              # still blocked at it, nothing skipped past
        d3 = json.loads(call("GET", self.base + "/v1/reminders/wait?after=" + urllib.parse.quote(d["token"]), headers=H)[2])
        self.assertEqual([f["name"] for f in d3["files"]][:1], [bad]); self.assertEqual(len(d3["files"]), 2)   # once readable, it and the one after both arrive

if __name__ == "__main__": unittest.main()
