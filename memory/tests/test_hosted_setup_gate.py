"""Locking the vault is part of signing up: until it is locked, a signed-in account reaches only the setup page, sign-out, delete, export and the public pages."""
import json, os, secrets, sys, tempfile, threading, unittest, urllib.parse
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentvault import seal
from agentvault.hosted import webauthn as w
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store
from test_hosted_passkeys import Passkey
from test_hosted_server import CHALLENGE, PUB, REDIR, call

PASS = "a long enough passphrase"

class SetupGateTests(unittest.TestCase):
    def serve(self, **auth_kw):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail = Store(Path(self.d.name)), []
        self.auth = Auth(self.store, **auth_kw)
        self.srv = make_server(self.store, self.auth, PUB, lambda e, l: self.mail.append((e, l)), port=0, encrypt=True, admins=["boss@x.io"])
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
    def setUp(self): self.serve()

    def form(self, path, body, ck=None): return call("POST", self.base + path, body, ck, form=True)
    def get(self, path, ck=None): return call("GET", self.base + path, headers=ck)
    def j(self, path, body, ck=None):
        st, _, b = call("POST", self.base + path, body, ck); return st, json.loads(b)
    def session(self, email="ada@example.com"):
        self.form("/login", {"email": email}); tok = self.mail[-1][1].split("t=")[1]
        st, h, _ = self.form("/login/verify", {"t": tok}); return {"Cookie": h["Set-Cookie"].split(";")[0]}
    def link_code(self): return json.loads(call("POST", self.base + "/v1/link/start", {"name": "Mac"})[2])["code"].replace("-", "")
    def oauth_q(self):
        cid = json.loads(call("POST", self.base + "/register", {"redirect_uris": [REDIR], "client_name": "Claude"})[2])["client_id"]
        return {"response_type": "code", "client_id": cid, "redirect_uri": REDIR, "code_challenge": CHALLENGE, "code_challenge_method": "S256"}
    def sent_to_setup(self, st, h):
        self.assertEqual(st, 302); self.assertTrue(h["Location"].startswith("/account/setup?"), h["Location"]); return urllib.parse.parse_qs(h["Location"].split("?", 1)[1])["next"][0]
    def enroll(self, ck, pk, prf, setup=True, nxt="/account"):
        st, o = self.j("/webauthn/register/options", {}, ck); self.assertEqual(st, 200)
        return self.j("/webauthn/register/finish", dict(pk.create(o["publicKey"]["challenge"]), prf=prf, setup=setup, next=nxt), ck)

    def test_a_new_account_reaches_nothing_but_setup_until_it_is_locked(self):
        ck = self.session(); code, q = self.link_code(), self.oauth_q()
        for path in ("/account", "/connect", "/billing/portal", "/admin"): self.assertEqual(self.sent_to_setup(*self.get(path, ck)[:2]), "/account", path)
        self.assertEqual(self.sent_to_setup(*self.get("/link?code=" + code, ck)[:2]), "/link?code=" + code)
        self.assertEqual(self.sent_to_setup(*self.get("/authorize?" + urllib.parse.urlencode(q), ck)[:2]), "/authorize?" + urllib.parse.urlencode(q))
        for path, body in (("/link", {"code": code, "decision": "allow"}), ("/authorize", dict(q, decision="allow")), ("/account/devices", {"name": "x"}), ("/account/devices/revoke", {"id": "x"}),
                           ("/account/signout-all", {}), ("/admin/invite", {"email": "a@b.io"}), ("/account/passkeys/remove", {"id": "x"})):
            self.sent_to_setup(*self.form(path, body, ck)[:2])
        st, _, page = self.get("/account/setup?next=/account", ck); self.assertEqual(st, 200); self.assertIn("Create a passkey", page); self.assertIn("Use a passphrase instead", page)
        for path in ("/privacy", "/terms"): self.assertEqual(self.get(path, ck)[0], 200, path)
        self.assertNotEqual(self.get("/static/nothing.css", ck)[0], 302)

    def test_the_passkey_path_locks_the_vault_and_continues_to_the_rebuilt_next(self):
        ck, pk, prf = self.session(), Passkey(), w.b64u(secrets.token_bytes(32)); code = self.link_code()
        nxt = self.sent_to_setup(*self.get("/link?code=" + code, ck)[:2])
        st, r = self.enroll(ck, pk, prf, nxt=nxt); self.assertEqual((st, r["next"]), (200, "/account/vault/recovery"))
        self.assertTrue(self.store.encrypted(self.store.by_email("ada@example.com")))
        page = self.get("/account/vault/recovery", ck)[2]; self.assertIn("recovery-code", page); self.assertIn('href="/link?code=%s"' % code, page)
        self.assertEqual(self.get("/account", ck)[0], 200); self.assertEqual(self.get("/link?code=" + code, ck)[0], 200)             # the gate is open now

    def test_the_passphrase_path_locks_the_vault_and_continues_to_the_rebuilt_next(self):
        ck, q = self.session(), self.oauth_q()
        nxt = self.sent_to_setup(*self.get("/authorize?" + urllib.parse.urlencode(q), ck)[:2])
        st, _, page = self.form("/account/vault", {"passphrase": PASS, "confirm": PASS, "next": nxt}, ck)
        self.assertEqual(st, 200); self.assertIn("recovery-code", page); self.assertIn("/authorize?", page)
        self.assertTrue(self.store.encrypted(self.store.by_email("ada@example.com")))
        st, _, bad = self.form("/account/vault", {"passphrase": PASS, "confirm": "nope nope nope", "next": nxt}, self.session("bob@example.com")); self.assertIn("don&#x27;t match", bad)
        self.assertFalse(self.store.encrypted(self.store.by_email("bob@example.com")))

    def test_a_passkey_that_cannot_make_the_secret_is_not_kept_and_the_passphrase_still_works(self):
        ck, pk = self.session(), Passkey(); uid = self.store.by_email("ada@example.com")
        st, r = self.enroll(ck, pk, ""); self.assertEqual(st, 400); self.assertIn("Use a passphrase instead", r["error"])
        st, r = self.enroll(ck, Passkey(), "", setup=False); self.assertEqual(st, 400)      # nor a sign-in-only passkey, whatever the page asked for
        self.assertEqual(self.store.passkeys(uid), []); self.assertFalse(self.store.encrypted(uid))
        self.sent_to_setup(*self.get("/account", ck)[:2])
        self.assertIn("recovery-code", self.form("/account/vault", {"passphrase": PASS, "confirm": PASS, "next": "/account"}, ck)[2]); self.assertTrue(self.store.encrypted(uid))

    def test_a_legacy_unlocked_account_is_forced_through_setup_and_its_notes_are_sealed(self):
        uid = self.store.create_user("old@example.com"); note = self.store.user_vault(uid) / "Claude" / "old.md"; note.parent.mkdir(parents=True, exist_ok=True); note.write_text("plain pineapple")
        ck = self.session("old@example.com"); self.sent_to_setup(*self.get("/account", ck)[:2])
        self.assertEqual(note.read_text(), "plain pineapple")
        self.assertIn("recovery-code", self.form("/account/vault", {"passphrase": PASS, "confirm": PASS, "next": "/account"}, ck)[2])
        self.assertTrue(note.read_bytes().startswith(seal.MAGIC)); self.assertNotIn(b"pineapple", note.read_bytes())

    def test_sign_out_export_and_delete_work_without_a_lock(self):
        uid = self.store.create_user("old@example.com"); note = self.store.user_vault(uid) / "x.md"; note.parent.mkdir(parents=True, exist_ok=True); note.write_text("keep me")
        ck = self.session("old@example.com")
        import zipfile, io, urllib.request
        r = urllib.request.urlopen(urllib.request.Request(self.base + "/account/export", data=b"", headers=dict(ck, Origin=PUB)))      # a zip is binary, which call() can't decode
        self.assertEqual((r.status, r.headers["Content-Type"]), (200, "application/zip")); self.assertEqual(zipfile.ZipFile(io.BytesIO(r.read())).read("Vault/x.md"), b"keep me")
        self.assertEqual(self.form("/logout", {}, ck)[0], 302)
        ck = self.session("old@example.com")
        st, h, _ = self.form("/account/delete", {"confirm": "old@example.com"}, ck); self.assertEqual((st, h["Location"]), (302, "/goodbye")); self.assertIsNone(self.store.by_email("old@example.com"))

    def test_next_is_rebuilt_on_the_server_and_never_an_open_redirect(self):
        ck = self.session()
        for evil in ("https://evil.example/", "//evil.example/x", "/\\evil.example", "javascript:alert(1)", "/account@evil.example"):
            page = self.get("/account/setup?" + urllib.parse.urlencode({"next": evil}), ck)[2]; self.assertNotIn("evil", page); self.assertIn('name="next" value="/account"', page)
            _, _, done = self.form("/account/vault", {"passphrase": "short", "confirm": "short", "next": evil}, ck); self.assertNotIn("evil", done)
        bad = {"response_type": "code", "client_id": "nope", "redirect_uri": "https://evil.example/cb"}
        self.assertEqual(self.sent_to_setup(*self.get("/authorize?" + urllib.parse.urlencode(bad), ck)[:2]), "/account")      # an invalid request is not carried over
        self.assertEqual(self.sent_to_setup(*self.get("/link?code=ZZZZZZZZ&next=https://evil.example", ck)[:2]), "/account")
        self.assertEqual(self.get("/account/setup?next=/link%3Fcode%3DAB", self.session("zed@example.com"))[0], 200)
        # once locked, a setup page with a next goes only to a local path
        self.form("/account/vault", {"passphrase": PASS, "confirm": PASS, "next": "/account"}, ck)
        self.assertEqual(self.get("/account/setup?next=https://evil.example", ck)[1]["Location"], "/account")

    def test_the_invite_and_user_limits_hold_at_request_and_at_verify(self):
        self.serve(invite_only=True, max_users=1)
        self.assertIn("closed beta", self.form("/login", {"email": "nobody@example.com"})[2]); self.assertEqual(self.mail, [])           # at request
        self.store.invite("a@example.com"); self.store.invite("b@example.com")
        ta, tb = self.auth.start_login("a@example.com"), self.auth.start_login("b@example.com")
        self.assertEqual(self.form("/login/verify", {"t": ta})[0], 302); self.assertEqual(self.store.user_count(), 1)
        self.assertEqual(self.form("/login/verify", {"t": tb})[0], 400); self.assertIsNone(self.store.by_email("b@example.com"))        # at verify: the beta filled meanwhile
        self.assertIn("full", self.form("/login", {"email": "b@example.com"})[2])

class HeaderInjectionTests(SetupGateTests):
    def raw(self, target):
        import socket
        so = socket.create_connection(self.base[7:].split(":")[0:1] + [self.srv.server_address[1]]); so.sendall(("GET %s HTTP/1.1\r\nHost: x\r\nCookie: %s\r\nConnection: close\r\n\r\n" % (target, self.ck["Cookie"])).encode())
        out = b""
        while (c := so.recv(65536)): out += c
        so.close(); return out.split(b"\r\n\r\n")[0].decode().split("\r\n")
    def test_setup_next_cannot_inject_a_header_or_a_cookie(self):
        self.ck = self.session()
        evil = "/link?%0d%0aSet-Cookie:%20av_session%3Dattacker%3B%20Path%3D/"
        for nxt in (evil, "/authorize?%0d%0aX-Injected:%201", "/account%0d%0aX-Injected:%201", "/link?code=%0d%0aX-Injected:%201"):
            lines = self.raw("/account/setup?next=" + nxt); self.assertFalse([l for l in lines if l.lower().startswith(("x-injected", "set-cookie"))], (nxt, lines))
        # locked account: setup redirects to the rebuilt next, still no extra header
        pk, prf = Passkey(), w.b64u(secrets.token_bytes(32)); self.enroll(self.ck, pk, prf)
        lines = self.raw("/account/setup?next=" + evil)
        self.assertTrue(lines[0].split()[1] == "302"); self.assertIn("Location: /account", lines)
        self.assertFalse([l for l in lines if l.lower().startswith(("x-injected", "set-cookie"))], lines)
    def test_next_path_is_rebuilt_not_copied(self):
        self.ck = self.session(); code = self.link_code()
        self.assertEqual(self.sent_to_setup(*self.get("/link?code=" + code, self.ck)[:2]), "/link?code=" + code)
        st, _, page = self.get("/account/setup?next=/link?code=" + code, self.ck); self.assertIn("/link?code=" + code, page)
        st, _, page = self.get("/account/setup?next=/link?code=bogus", self.ck); self.assertNotIn("bogus", page)
    def test_send_refuses_cr_lf_nul_in_any_header(self):
        from agentvault.remote.server import header_ok
        for bad in ("a\r\nX: 1", "a\nb", "a\0b"):
            self.assertFalse(header_ok({"Location": bad})); self.assertFalse(header_ok({bad: "v"}))
        self.assertTrue(header_ok({"Location": "/ok?x=1"}))

if __name__ == "__main__": unittest.main()
