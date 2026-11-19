"""Hostile input against a real local server. Each test is something an attacker or a careless client might try."""
import json, sys, tempfile, threading, unittest, urllib.parse
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentvault.hosted import devices, keys
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store
from test_hosted_server import CHALLENGE, PUB, REDIR, VERIFIER, call
from test_hosted_devices import sess

PASS = "a long enough passphrase"

class AttackTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail = Store(Path(self.d.name)), []
        self.srv = make_server(self.store, Auth(self.store, invite_only=True), PUB, lambda e, l: self.mail.append((e, l)), port=0, admins=["boss@x.io"], encrypt=True)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        self.users = {}
        for n in ("ann", "bob"):
            self.store.invite(n + "@x.io"); self.users[n] = self.make_user(n + "@x.io")

    def form(self, path, body, ck=None): return call("POST", self.base + path, body, ck, form=True)
    def make_user(self, email):
        self.form("/login", {"email": email}); tok = self.mail[-1][1].split("t=")[1]
        _, h, _ = self.form("/login/verify", {"t": tok}); ck = {"Cookie": h["Set-Cookie"].split(";")[0]}
        uid = self.store.by_email(email); keys.setup(self.store, uid, PASS)
        s = json.loads(call("POST", self.base + "/v1/link/start", {"name": "Mac"})[2]); code = s["code"].replace("-", "")
        self.form("/link", {"code": code, "decision": "allow", "passphrase": PASS}, ck)
        tok = json.loads(call("POST", self.base + "/v1/link/poll", {"secret": s["secret"]})[2])["token"]
        return {"ck": ck, "uid": uid, "tok": tok, "hdr": {"Authorization": "Bearer " + tok}}
    def assistant(self, who):
        cid = json.loads(call("POST", self.base + "/register", {"redirect_uris": [REDIR], "client_name": "Claude"})[2])["client_id"]
        q = {"response_type": "code", "client_id": cid, "redirect_uri": REDIR, "code_challenge": CHALLENGE, "code_challenge_method": "S256", "decision": "allow", "passphrase": PASS}
        st, h, _ = self.form("/authorize", q, self.users[who]["ck"]); code = urllib.parse.parse_qs(urllib.parse.urlparse(h["Location"]).query)["code"][0]
        return json.loads(call("POST", self.base + "/token", {"grant_type": "authorization_code", "code": code, "client_id": cid, "redirect_uri": REDIR, "code_verifier": VERIFIER}, form=True)[2])["access_token"]
    def tool(self, token, name, args):
        r = json.loads(call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}, {"Authorization": "Bearer " + token})[2])
        return r["result"]["content"][0]["text"]

    def test_one_user_cannot_read_anothers_notes_by_any_route(self):
        call("POST", self.base + "/v1/ingest", {"sessions": [sess("secret1", [{"role": "user", "text": "ann's private pineapple plan", "ts": "2026-11-14T10:00:00Z"}])]}, self.users["ann"]["hdr"])
        ann_path = json.loads(self.tool(self.assistant("ann"), "vault_search", {"query": "pineapple"}))[0]["path"]
        bob = self.assistant("bob")
        self.assertEqual(self.tool(bob, "vault_search", {"query": "pineapple"}), "[]")                        # search sees only your own
        for p in (ann_path, "../" + self.users["ann"]["uid"] + "/Vault/" + ann_path, "../../" + ann_path, "/" + ann_path, ann_path.replace("/", "\\")):
            self.assertIn("error", self.tool(bob, "vault_read", {"path": p}), p)                           # a path is never a way into someone else's vault
        self.assertEqual(call("GET", self.base + "/v1/reminders/wait?after=", headers=self.users["bob"]["hdr"])[0], 200)
        self.assertEqual(self.form("/account/passkeys/remove", {"id": "x"}, self.users["bob"]["ck"])[0], 302)

    def test_a_revoked_device_and_a_swapped_token_open_nothing(self):
        ann, bob = self.users["ann"], self.users["bob"]
        devices.revoke(self.store, ann["uid"], devices.listing(self.store, ann["uid"])[0]["id"])
        self.assertEqual(call("POST", self.base + "/v1/ingest", {"sessions": [sess("x")]}, ann["hdr"])[0], 401)
        self.assertEqual(call("GET", self.base + "/v1/me", headers={"Authorization": "Bearer " + bob["tok"][:-2] + "xx"})[0], 401)      # one wrong character
        self.assertEqual(call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, {"Authorization": "Bearer " + bob["tok"]})[0], 401)   # a device key is not an assistant key

    def test_header_injection_through_the_email_field_sends_nothing(self):
        before = len(self.mail)
        for evil in ("ann@x.io\r\nBcc: attacker@evil.example", "ann@x.io\nSubject: pwned", "ann@x.io%0d%0aBcc:a@b.c"):
            call("POST", self.base + "/login", {"email": evil}, form=True)
        self.assertEqual(len(self.mail), before)

    def test_what_a_stranger_types_is_never_run_as_script(self):
        evil = '<script>alert(1)</script><img src=x onerror=alert(1)>'
        self.assertEqual(call("POST", self.base + "/waitlist", {"email": "z@x.io", "note": evil}, form=True)[0], 200)
        self.store.create_user("boss@x.io"); self.form("/login", {"email": "boss@x.io"}); tok = self.mail[-1][1].split("t=")[1]
        _, h, _ = self.form("/login/verify", {"t": tok}); bk = {"Cookie": h["Set-Cookie"].split(";")[0]}
        self.form("/account/vault", {"passphrase": "a long enough passphrase", "confirm": "a long enough passphrase", "next": "/account"}, bk)
        page = call("GET", self.base + "/admin", headers=bk)[2]
        self.assertNotIn("<script>alert", page); self.assertIn("&lt;script&gt;", page)
        for q in ("/login?x=%22%3E%3Cscript%3E", "/link?code=%22%3E%3Cscript%3E", "/authorize?client_id=%22%3E%3Cscript%3E"):
            self.assertNotIn("<script>alert", call("GET", self.base + q)[2])

    def test_a_forged_next_page_cannot_send_people_to_another_site(self):
        ck = self.users["ann"]["ck"]; ck2 = {"Cookie": ck["Cookie"]}
        st, h, body = self.form("/account/vault", {"passphrase": "x" * 3, "confirm": "x" * 3, "next": "https://evil.example/phish"}, ck2)
        self.assertNotIn("evil.example", body)
        st, h, _ = call("POST", self.base + "/login", {"email": "ann@x.io", "client_id": "nope", "redirect_uri": "https://evil.example/", "response_type": "code"}, form=True)
        self.assertEqual(len(self.mail) and ("evil.example" in self.mail[-1][1]), False)

    def test_the_cookie_is_locked_down_and_only_assistants_on_known_sites_can_register(self):
        st, h, _ = self.form("/login/verify", {"t": "bad"})
        self.store.create_user("c@x.io"); self.form("/login", {"email": "ann@x.io"}); tok = self.mail[-1][1].split("t=")[1]
        cookie = self.form("/login/verify", {"t": tok})[1]["Set-Cookie"]
        for flag in ("HttpOnly", "SameSite=Lax", "Secure", "Path=/"): self.assertIn(flag, cookie)       # PUB is https, so Secure is set
        self.assertEqual(call("POST", self.base + "/register", {"redirect_uris": ["https://evil.example/cb"], "client_name": "x"})[0], 400)
        self.assertEqual(call("POST", self.base + "/register", {"redirect_uris": ["http://claude.ai/cb"], "client_name": "x"})[0], 400)   # https only

    def test_command_line_tools_may_sign_in_through_their_own_machine_and_nothing_else(self):
        reg = lambda uri: call("POST", self.base + "/register", {"redirect_uris": [uri], "client_name": "Codex"})[0]
        for ok in ("http://127.0.0.1:49198/callback/abc", "http://localhost:8123/callback", "http://[::1]:5000/cb"): self.assertEqual(reg(ok), 201, ok)
        for bad in ("http://evil.example/cb", "http://127.0.0.1.evil.example/cb", "http://localhost.evil.com:80/cb", "http://127.0.0.1@evil.example/cb", "http://user:pw@127.0.0.1/cb",
                    "https://127.0.0.1/cb", "http://192.168.1.5:80/cb", "http://127.0.0.1/cb#frag", "ftp://127.0.0.1/cb", "javascript:alert(1)"):
            self.assertEqual(reg(bad), 400, bad)
        # a registered loopback address may use another port next time, but not another path or host
        cid = json.loads(call("POST", self.base + "/register", {"redirect_uris": ["http://127.0.0.1:1111/callback/x"], "client_name": "Codex"})[2])["client_id"]
        base_q = {"response_type": "code", "client_id": cid, "code_challenge": CHALLENGE, "code_challenge_method": "S256"}
        ck = self.users["ann"]["ck"]
        self.assertEqual(call("GET", self.base + "/authorize?" + urllib.parse.urlencode(dict(base_q, redirect_uri="http://127.0.0.1:2222/callback/x")), headers=ck)[0], 200)
        for bad in ("http://127.0.0.1:2222/callback/y", "http://localhost:1111/callback/x", "http://evil.example:1111/callback/x"):
            self.assertEqual(call("GET", self.base + "/authorize?" + urllib.parse.urlencode(dict(base_q, redirect_uri=bad)), headers=ck)[0], 400, bad)
        page = call("GET", self.base + "/authorize?" + urllib.parse.urlencode(dict(base_q, redirect_uri="http://127.0.0.1:2222/callback/x")), headers=ck)[2]
        self.assertIn("Codex on this Mac", page)                                      # the name is the tool's own claim, so the page says where it runs

    def test_the_page_policy_lets_a_sign_in_return_to_this_mac_and_to_https_apps_only(self):
        csp = call("GET", self.base + "/login")[1]["Content-Security-Policy"]
        action = [d for d in csp.split(";") if d.strip().startswith("form-action")][0]
        for ok in ("'self'", "https:", "http://127.0.0.1:*", "http://localhost:*"): self.assertIn(ok, action)
        self.assertNotIn(" http: ", action + " "); self.assertNotIn("*;", action); self.assertIn("script-src 'self'", csp)       # no plain-http sites, no wildcard, scripts still only ours

    def test_oversized_and_malformed_bodies_are_refused_not_processed(self):
        import http.client, urllib.error, urllib.request
        c = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=10)       # claim 9 MB and send none: refused on the header, before anything is read
        c.putrequest("POST", "/v1/ingest"); c.putheader("Authorization", self.users["ann"]["hdr"]["Authorization"]); c.putheader("Content-Type", "application/json")
        c.putheader("Content-Length", str(9 * 1024 * 1024)); c.endheaders(); self.assertEqual(c.getresponse().status, 413); c.close()
        c = http.client.HTTPConnection("127.0.0.1", self.srv.server_address[1], timeout=10)       # a negative length must not stall a worker
        c.putrequest("POST", "/v1/ingest"); c.putheader("Authorization", self.users["ann"]["hdr"]["Authorization"]); c.putheader("Content-Length", "-5"); c.endheaders(); self.assertEqual(c.getresponse().status, 400); c.close()
        for body in (b"not json", b"[]", b'{"sessions": "no"}', b'{"sessions": [{"meta": {"agent": "../../etc", "session_id": "s"}, "turns": []}]}'):
            r = urllib.request.Request(self.base + "/v1/ingest", data=body, headers={**self.users["ann"]["hdr"], "Content-Type": "application/json"}, method="POST")
            try: code = urllib.request.urlopen(r, timeout=10).status
            except urllib.error.HTTPError as e: code = e.code; e.close()
            self.assertEqual(code, 400, body)

    def test_nothing_secret_reaches_the_logs(self):
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            self.form("/login", {"email": "ann@x.io"}); tok = self.mail[-1][1].split("t=")[1]
            self.form("/login/verify", {"t": tok}); call("GET", self.base + "/v1/me", headers=self.users["ann"]["hdr"]); call("GET", self.base + "/authorize?client_id=c&code_challenge=abc")
        log = buf.getvalue()
        for secret in (tok, self.users["ann"]["tok"], PASS, "ann@x.io", "code_challenge"): self.assertNotIn(secret, log)

if __name__ == "__main__": unittest.main()
