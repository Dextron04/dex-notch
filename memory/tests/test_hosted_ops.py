import contextlib, io, json, os, sqlite3, subprocess, sys, tempfile, threading, time, unittest, urllib.error, urllib.parse, urllib.request, zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.hosted import billing, devices, ingest, store as store_mod, tools
from agentvault.hosted.billing import BillingError, Stripe, apply_event
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store

NR = type("NR", (urllib.request.HTTPRedirectHandler,), {"redirect_request": lambda self, *a, **k: None})
OPENER = urllib.request.build_opener(NR)
def call(method, url, body=None, headers=None, form=False, raw=None):
    data = raw if raw is not None else (None if body is None else (urllib.parse.urlencode(body).encode() if form else json.dumps(body).encode()))
    try: r = OPENER.open(urllib.request.Request(url, data=data, method=method, headers=headers or {}), timeout=10); return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as e: b = e.read(); e.close(); return e.code, {k.lower(): v for k, v in e.headers.items()}, b
def sess(sid="s1", text="hello pineapple"):
    return {"meta": {"agent": "codex", "session_id": sid, "project": "p", "cwd": "/x", "started": "2026-11-14T10:00:00Z", "title": "T"}, "turns": [{"role": "user", "text": text, "ts": "2026-11-14T10:00:00Z"}]}

class StoreOpsTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.s = Store(Path(self.d.name)); self.u = self.s.create_user("a@x.io"); self.s.grant(self.u)

    def test_delete_account_erases_everything_and_frees_the_email(self):
        ingest.ingest(self.s, self.u, {"sessions": [sess()]}); _, tok = devices.create(self.s, self.u, "Mac")
        keep = self.s.create_user("b@x.io"); self.s.grant(keep); ingest.ingest(self.s, keep, {"sessions": [sess("k", "other tenant")]})
        self.s.delete_account(self.u)
        self.assertFalse((Path(self.d.name) / "data" / self.u).exists()); self.assertIsNone(devices.check(self.s, tok))
        self.assertEqual((self.s.status(self.u), self.s.entitled(self.u)), ("deleted", False)); self.assertIsNone(self.s.email(self.u) and self.s.by_email("a@x.io"))
        self.assertIn("other tenant", tools.call(self.s, keep, "vault_search", {"query": "tenant"}))                     # nobody else was touched
        self.s.delete_account(self.u)                                                                                    # twice is fine
        again = self.s.create_user("a@x.io"); self.assertNotEqual(again, self.u)                                         # the address can sign up again
        self.assertEqual(apply_event(self.s, {"id": "late", "type": "customer.subscription.updated", "created": time.time() + 99,
                                              "data": {"object": {"id": "s", "customer": "c", "status": "active", "metadata": {"user_id": self.u}}}}), "ignored")
        self.assertEqual(self.s.status(self.u), "deleted")                                                               # a late Stripe event cannot revive it
        for bad in ("", "../x", "u_short"):
            with self.assertRaises(ValueError): self.s.delete_account(bad)
        with self.assertRaises(KeyError): self.s.delete_account("u_" + "A" * 22)

    def test_retention_candidates_and_stats(self):
        self.s.set_status(self.u, "canceled"); t = time.time()
        self.assertEqual(self.s.canceled_before(t + 1), [self.u]); self.assertEqual(self.s.canceled_before(t - 100), [])
        self.s.grant(self.u); self.assertEqual(self.s.canceled_before(t + 1), [])                                        # came back: kept
        st = self.s.stats(); self.assertEqual(st["users"], {"active": 1}); self.assertGreater(st["db_bytes"], 0)

    def test_old_database_gains_the_new_column(self):
        p = Path(self.d.name) / "old"; p.mkdir()
        c = sqlite3.connect(p / "hosted.db"); c.execute("CREATE TABLE users(id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, created_at REAL NOT NULL, status TEXT NOT NULL DEFAULT 'pending')")
        c.execute("INSERT INTO users VALUES('u_" + "A" * 22 + "','o@x.io',1,'active')"); c.commit(); c.close()
        s = Store(p); self.assertEqual(s.status("u_" + "A" * 22), "active"); s.set_status("u_" + "A" * 22, "canceled")

    def test_write_paths_respect_quotas(self):
        real = store_mod.PAID_QUOTA; self.addCleanup(setattr, store_mod, "PAID_QUOTA", real)
        tools.call(self.s, self.u, "remember", {"title": "t", "content": "c" * 3000, "source": "claude"})
        store_mod.PAID_QUOTA = 1000
        with self.assertRaisesRegex(PermissionError, "quota"): tools.call(self.s, self.u, "remember", {"title": "t2", "content": "more", "source": "claude"})
        with self.assertRaisesRegex(PermissionError, "quota"): tools.call(self.s, self.u, "remind", {"text": "x", "when": "2027-01-01T09:00:00+00:00", "source": "claude"})
        self.assertEqual(len(json.loads(tools.call(self.s, self.u, "vault_search", {"query": "c" * 50}))), 1)                  # reading still works over quota
        store_mod.PAID_QUOTA = real; old, tools.MAX_PENDING_REMINDERS = tools.MAX_PENDING_REMINDERS, 2; self.addCleanup(setattr, tools, "MAX_PENDING_REMINDERS", old)
        for i in range(2): tools.call(self.s, self.u, "remind", {"text": "r%d" % i, "when": "2027-01-01T09:00:00+00:00", "source": "claude"})
        with self.assertRaisesRegex(PermissionError, "too many"): tools.call(self.s, self.u, "remind", {"text": "r9", "when": "2027-01-01T09:00:00+00:00", "source": "claude"})

    def test_purge_cli(self):
        self.s.set_status(self.u, "canceled")
        with sqlite3.connect(self.s.db) as c: c.execute("UPDATE users SET status_at=? WHERE id=?", (time.time() - 40 * 86400, self.u))
        run = lambda *a: subprocess.run([sys.executable, "-m", "agentvault.hosted", *a, "--root", self.d.name], capture_output=True, text=True, cwd=Path(__file__).resolve().parents[1])
        out = run("purge", "--days", "30"); self.assertIn("dry run", out.stdout); self.assertEqual(self.s.status(self.u), "canceled")
        self.assertIn(self.u, run("purge", "--days", "30").stdout)
        self.assertEqual(run("purge", "--days", "60").stdout.count(self.u), 0)                                              # not yet 60 days old
        self.assertIn("erased", run("purge", "--days", "30", "--yes").stdout); self.assertEqual(self.s.status(self.u), "deleted")
        self.assertIn('"deleted": 1', run("stats").stdout)

class ServerOpsTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail, self.cancelled, self.fail_cancel = Store(Path(self.d.name)), [], [], [False]
        def delete(path):
            if self.fail_cancel[0]: raise BillingError("stripe request failed: HTTPError")
            self.cancelled.append(path); return {}
        self.auth = Auth(self.store)
        self.srv = make_server(self.store, self.auth, "https://h.test", lambda e, l: self.mail.append((e, l)), Stripe("sk_test_x", "price_1", "https://h.test", post=lambda p, f: {"url": "u"}, delete=delete), b"w" * 30, port=0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def user(self, email, paid=True, sub="sub_123"):
        call("POST", self.base + "/login", {"email": email}, form=True)
        _, h, _ = call("POST", self.base + "/login/verify", {"t": self.mail[-1][1].split("t=")[1]}, form=True)
        uid = self.store.by_email(email)
        if paid:
            self.store.grant(uid)
            with self.store.conn() as c: c.execute("UPDATE billing SET stripe_sub_id=? WHERE user_id=?", (sub, uid))
        return uid, {"Cookie": h["set-cookie"].split(";")[0]}

    def test_export_has_my_data_only(self):
        a, ca = self.user("a@x.io"); b, _ = self.user("b@x.io", sub="sub_999")
        ingest.ingest(self.store, a, {"sessions": [sess("a1", "alpha note")]}); ingest.ingest(self.store, b, {"sessions": [sess("b1", "beta secret")]})
        os.symlink(self.store.user_vault(b) / "Sessions", self.store.user_vault(a) / "link")                          # a symlink into another tenant
        self.assertEqual(call("POST", self.base + "/account/export", {}, form=True)[0], 401)
        st, h, body = call("POST", self.base + "/account/export", {}, ca, form=True)
        self.assertEqual((st, h["content-type"], int(h["content-length"])), (200, "application/zip", len(body)))
        z = zipfile.ZipFile(io.BytesIO(body)); names = z.namelist(); blob = b"".join(z.read(n) for n in names)
        self.assertIn("account.json", names); self.assertIn(b"alpha note", blob); self.assertNotIn(b"beta secret", blob)
        self.assertEqual(json.loads(z.read("account.json"))["email"], "a@x.io")
        self.store.set_status(a, "canceled"); self.assertEqual(call("POST", self.base + "/account/export", {}, ca, form=True)[0], 200)   # canceled can still take their data

    def test_delete_needs_confirmation_cancels_billing_and_erases(self):
        uid, ck = self.user("a@x.io"); _, tok = devices.create(self.store, uid, "Mac"); ingest.ingest(self.store, uid, {"sessions": [sess()]})
        for body in ({}, {"confirm": "nope"}, {"confirm": "b@x.io"}): self.assertEqual(call("POST", self.base + "/account/delete", body, ck, form=True)[0], 400)
        self.assertEqual(call("POST", self.base + "/account/delete", {"confirm": "a@x.io"}, form=True)[0], 401)
        self.assertEqual(self.store.status(uid), "active")
        self.fail_cancel[0] = True
        st, _, b = call("POST", self.base + "/account/delete", {"confirm": "a@x.io"}, ck, form=True)
        self.assertEqual(st, 502); self.assertEqual(self.store.status(uid), "active"); self.assertTrue((Path(self.d.name) / "data" / uid).exists())   # nothing erased if billing couldn't be stopped
        self.fail_cancel[0] = False
        st, h, _ = call("POST", self.base + "/account/delete", {"confirm": " A@X.io "}, ck, form=True)
        self.assertEqual((st, h["location"]), (302, "/goodbye")); self.assertIn("Max-Age=0", h["set-cookie"])
        self.assertEqual(self.cancelled, ["/subscriptions/sub_123"]); self.assertEqual(self.store.status(uid), "deleted")
        self.assertFalse((Path(self.d.name) / "data" / uid).exists())
        self.assertEqual(call("POST", self.base + "/v1/ingest", {"sessions": [sess()]}, {"Authorization": "Bearer " + tok, "Content-Type": "application/json"})[0], 401)
        self.assertEqual(call("GET", self.base + "/account", headers=ck)[1]["location"], "/login")

    def test_deleting_a_canceled_account_does_not_touch_stripe(self):
        uid, ck = self.user("a@x.io"); self.store.set_status(uid, "canceled")
        self.assertEqual(call("POST", self.base + "/account/delete", {"confirm": "a@x.io"}, ck, form=True)[0], 302); self.assertEqual(self.cancelled, [])

    def test_mcp_rate_limit(self):
        uid, _ = self.user("a@x.io"); cid = self.auth.register(["https://claude.ai/cb"], "c")
        with self.store.conn() as c: tok = self.auth._tokens(c, uid, cid)["access_token"]
        codes = [call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "ping"}, {"Authorization": "Bearer " + tok, "Content-Type": "application/json"})[0] for _ in range(125)]
        self.assertEqual((codes.count(200), codes.count(429)), (120, 5))

    def test_health_and_the_access_log_never_holds_secrets(self):
        self.assertEqual(call("GET", self.base + "/healthz")[0], 200)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            call("POST", self.base + "/login", {"email": "log@x.io"}, form=True)
            call("GET", self.base + "/login/verify?t=" + self.mail[-1][1].split("t=")[1])
            call("POST", self.base + "/login/verify", {"t": self.mail[-1][1].split("t=")[1]}, form=True)
        log = err.getvalue()
        self.assertIn("POST /login 200", log); self.assertIn("GET /login/verify 200", log)
        for secret in (self.mail[-1][1].split("t=")[1], "log@x.io", "?t="): self.assertNotIn(secret, log)
        os.rename(self.store.db, str(self.store.db) + ".gone")
        self.assertEqual(call("GET", self.base + "/healthz")[0], 503)

if __name__ == "__main__": unittest.main()
