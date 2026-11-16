import base64, hashlib, json, re, sys, tempfile, threading, unittest, urllib.error, urllib.parse, urllib.request
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store

REDIR = "https://claude.ai/api/mcp/auth_callback"
PUB = "https://hosted.example.test"
VERIFIER = "v" * 50
CHALLENGE = base64.urlsafe_b64encode(hashlib.sha256(VERIFIER.encode()).digest()).rstrip(b"=").decode()

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
OPENER = urllib.request.build_opener(NoRedirect)

def call(method, url, body=None, headers=None, form=False):
    data = None if body is None else (urllib.parse.urlencode(body).encode() if form else json.dumps(body).encode())
    h = {"Content-Type": "application/x-www-form-urlencoded" if form else "application/json"}; h.update(headers or {})
    try:
        r = OPENER.open(urllib.request.Request(url, data=data, method=method, headers=h), timeout=10)
        return r.status, dict(r.headers), r.read().decode()
    except urllib.error.HTTPError as e:
        b = e.read().decode(); e.close(); return e.code, dict(e.headers), b

class HostedServerTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.t, self.mail = Store(Path(self.d.name)), [10_000.0], []
        self.auth = Auth(self.store, now=lambda: self.t[0])
        self.srv = make_server(self.store, self.auth, PUB, lambda e, l: self.mail.append((e, l)), port=0, now=lambda: self.t[0])
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        self.cid = json.loads(call("POST", self.base + "/register", {"redirect_uris": [REDIR], "client_name": "Claude"})[2])["client_id"]

    def oauth_q(self, state="s1"):
        return {"response_type": "code", "client_id": self.cid, "redirect_uri": REDIR, "code_challenge": CHALLENGE, "code_challenge_method": "S256", "state": state}

    def sign_in(self, email, q=None):
        """Magic-link login through /authorize; returns the session cookie header."""
        q = q or self.oauth_q()
        self.assertEqual(call("POST", self.base + "/login", dict(q, email=email), form=True)[0], 200)
        link = self.mail[-1][1]; self.assertTrue(link.startswith(PUB + "/login/verify?t="))
        tok = link.split("t=")[1]
        self.assertEqual(call("GET", self.base + "/login/verify?t=" + tok)[0], 200)             # a GET alone does not consume the link
        st, h, _ = call("POST", self.base + "/login/verify", {"t": tok}, form=True)
        self.assertEqual(st, 302); self.assertTrue(h["Location"].startswith("/authorize?"))
        self.assertRegex(h["Set-Cookie"], r"HttpOnly; SameSite=Lax")
        return {"Cookie": h["Set-Cookie"].split(";")[0]}, tok

    def tokens(self, email, grant=True):
        ck, _ = self.sign_in(email)
        if grant: self.store.grant(self.store.by_email(email))
        st, h, body = call("POST", self.base + "/authorize", dict(self.oauth_q(), decision="allow"), ck, form=True)
        self.assertEqual(st, 302, body)
        code = urllib.parse.parse_qs(urllib.parse.urlparse(h["Location"]).query)["code"][0]
        return json.loads(call("POST", self.base + "/token", {"grant_type": "authorization_code", "code": code, "client_id": self.cid,
                                                              "redirect_uri": REDIR, "code_verifier": VERIFIER}, form=True)[2])

    def mcp(self, tok, method, params=None):
        st, h, b = call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, {"Authorization": "Bearer " + tok})
        return st, (json.loads(b) if b else None)

    def text(self, tok, name, args):
        st, r = self.mcp(tok, "tools/call", {"name": name, "arguments": args}); self.assertEqual(st, 200)
        return r["result"]["content"][0]["text"]

    def test_full_flow_and_per_user_isolation(self):
        ta, tb = self.tokens("a@x.io"), self.tokens("b@x.io")
        self.assertIn("Saved to", self.text(ta["access_token"], "remember", {"title": "plan", "content": "alpha only", "source": "claude"}))
        self.assertIn("alpha", self.text(ta["access_token"], "vault_search", {"query": "alpha"}))
        self.assertEqual(json.loads(self.text(tb["access_token"], "vault_search", {"query": "alpha"})), [])
        names = [t["name"] for t in self.mcp(ta["access_token"], "tools/list")[1]["result"]["tools"]]
        self.assertEqual(sorted(names), ["remember", "remind", "vault_read", "vault_recent", "vault_search"])
        new = json.loads(call("POST", self.base + "/token", {"grant_type": "refresh_token", "refresh_token": ta["refresh_token"], "client_id": self.cid}, form=True)[2])
        self.assertEqual(self.mcp(new["access_token"], "ping")[0], 200)
        self.assertEqual(call("POST", self.base + "/token", {"grant_type": "refresh_token", "refresh_token": ta["refresh_token"], "client_id": self.cid}, form=True)[0], 400)  # rotated

    def test_entitlement_checked_on_every_call(self):
        ta = self.tokens("a@x.io"); uid = self.store.by_email("a@x.io")
        self.assertEqual(self.mcp(ta["access_token"], "ping")[0], 200)
        for st in ("canceled", "deleted", "pending"):
            self.store.set_status(uid, st); self.assertEqual(self.mcp(ta["access_token"], "ping")[0], 402, st)
        self.store.grant(uid); self.assertEqual(self.mcp(ta["access_token"], "ping")[0], 200)
        self.assertEqual(self.mcp("garbage", "ping")[0], 401)
        self.auth.revoke_all(uid); self.assertEqual(self.mcp(ta["access_token"], "ping")[0], 401)

    def test_unpaid_user_cannot_authorize(self):
        ck, _ = self.sign_in("a@x.io")
        st, _, body = call("GET", self.base + "/authorize?" + urllib.parse.urlencode(self.oauth_q()), headers=ck)
        self.assertEqual(st, 402); self.assertIn("aren't open yet", body)
        self.assertEqual(call("POST", self.base + "/authorize", dict(self.oauth_q(), decision="allow"), ck, form=True)[0], 402)

    def test_authorize_needs_session_and_deny_works(self):
        q = urllib.parse.urlencode(self.oauth_q())
        st, _, body = call("GET", self.base + "/authorize?" + q); self.assertIn("Email me a sign-in link", body)
        self.assertEqual(call("POST", self.base + "/authorize", dict(self.oauth_q(), decision="allow"), form=True)[0], 401)
        ck, _ = self.sign_in("a@x.io"); self.store.grant(self.store.by_email("a@x.io"))
        self.assertIn("Allow", call("GET", self.base + "/authorize?" + q, headers=ck)[2])
        loc = call("POST", self.base + "/authorize", dict(self.oauth_q(), decision="deny"), ck, form=True)[1]["Location"]
        self.assertIn("error=access_denied", loc); self.assertNotIn("code=", loc)

    def test_magic_link_is_single_use_and_expires(self):
        _, tok = self.sign_in("a@x.io")
        self.assertEqual(call("POST", self.base + "/login/verify", {"t": tok}, form=True)[0], 400)
        self.assertEqual(call("POST", self.base + "/login", {"email": "b@x.io"}, form=True)[0], 200)
        tok2 = self.mail[-1][1].split("t=")[1]; self.t[0] += 901
        self.assertEqual(call("POST", self.base + "/login/verify", {"t": tok2}, form=True)[0], 400)
        self.assertIsNone(self.store.by_email("b@x.io"))                       # an unverified address never became an account

    def test_login_never_reveals_accounts_and_is_rate_limited(self):
        self.sign_in("a@x.io"); n = len(self.mail)
        known = call("POST", self.base + "/login", {"email": "a@x.io"}, form=True)
        unknown = call("POST", self.base + "/login", {"email": "nobody@x.io"}, form=True)
        self.assertEqual(known[2], unknown[2]); self.assertEqual(len(self.mail), n + 2)
        for _ in range(5): call("POST", self.base + "/login", {"email": "flood@x.io"}, form=True)
        self.assertEqual(len([m for m in self.mail if m[0] == "flood@x.io"]), 3)  # per-address cap
        self.t[0] += 901; call("POST", self.base + "/login", {"email": "flood@x.io"}, form=True)
        self.assertEqual(len([m for m in self.mail if m[0] == "flood@x.io"]), 4)

    def test_oauth_hardening(self):
        self.assertEqual(call("POST", self.base + "/register", {"redirect_uris": ["https://evil.test/cb"]})[0], 400)
        self.assertEqual(call("GET", self.base + "/authorize?" + urllib.parse.urlencode(dict(self.oauth_q(), redirect_uri="https://claude.ai/other")))[0], 400)
        self.assertEqual(call("GET", self.base + "/authorize?" + urllib.parse.urlencode(dict(self.oauth_q(), code_challenge_method="plain")))[0], 400)
        self.assertEqual(call("POST", self.base + "/login", dict(self.oauth_q(), redirect_uri="https://evil.test/", email="a@x.io"), form=True)[0], 400)
        ck, _ = self.sign_in("a@x.io"); self.store.grant(self.store.by_email("a@x.io"))
        loc = call("POST", self.base + "/authorize", dict(self.oauth_q(), decision="allow"), ck, form=True)[1]["Location"]
        code = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)["code"][0]
        bad = {"grant_type": "authorization_code", "code": code, "client_id": self.cid, "redirect_uri": REDIR, "code_verifier": "wrong" * 10}
        self.assertEqual(call("POST", self.base + "/token", bad, form=True)[0], 400)
        self.assertEqual(call("POST", self.base + "/token", dict(bad, code_verifier=VERIFIER), form=True)[0], 400)  # the failed try burned the code
        self.assertEqual(call("GET", self.base + "/nope")[0], 404)

if __name__ == "__main__": unittest.main()
