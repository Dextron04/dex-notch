import base64, hashlib, json, sys, tempfile, threading, unittest, urllib.error, urllib.parse, urllib.request
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import notes
from agentvault.model import Turn, SessionMeta
from agentvault.remote.oauth import OAuthStore
from agentvault.remote.server import make_server

REDIR = "https://chatgpt.com/connector_platform_oauth_redirect"
PUB = "https://memory.example.test"

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
OPENER = urllib.request.build_opener(NoRedirect)

def call(method, url, body=None, headers=None, form=False):
    data = None
    if body is not None:
        data = urllib.parse.urlencode(body).encode() if form else json.dumps(body).encode()
    h = {"Content-Type": "application/x-www-form-urlencoded" if form else "application/json"}
    h.update(headers or {})
    try:
        r = OPENER.open(urllib.request.Request(url, data=data, method=method, headers=h), timeout=10)
        return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        body = e.read(); e.close()
        return e.code, dict(e.headers), body

class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        root = Path(self.d.name); self.vault = root / "Vault"
        notes.append_turns(self.vault, SessionMeta("codex", "aaaaaaaaaa1", "auth", "/x", "2026-11-14T10:00:00Z", "Auth lock fix", "/s"),
                           [Turn("user", "why does the keychain prompt appear", "2026-11-14T10:00:00Z")])
        self.store = OAuthStore(root / "oauth.json")
        self.t = [10_000.0]
        self.srv = make_server(self.vault, self.store, "correct horse", PUB, port=0, now=lambda: self.t[0])
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    # -- helpers
    def register(self, redirs=(REDIR,)):
        return call("POST", self.base + "/register", {"client_name": "ChatGPT", "redirect_uris": list(redirs)})

    def authorize(self, cid, passphrase="correct horse", redir=REDIR, ip=None):
        v = "v" * 50
        ch = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()
        q = {"response_type": "code", "client_id": cid, "redirect_uri": redir, "code_challenge": ch, "code_challenge_method": "S256", "state": "st1"}
        return v, q, call("POST", self.base + "/authorize", dict(q, passphrase=passphrase), {"CF-Connecting-IP": ip} if ip else None, form=True)

    def token(self):
        cid = json.loads(self.register()[2])["client_id"]
        v, q, (st, h, _) = self.authorize(cid)
        self.assertEqual(st, 302)
        code = urllib.parse.parse_qs(urllib.parse.urlparse(h["Location"]).query)["code"][0]
        st, _, body = call("POST", self.base + "/token", {"grant_type": "authorization_code", "code": code, "client_id": cid,
                                                           "redirect_uri": REDIR, "code_verifier": v}, form=True)
        self.assertEqual(st, 200); return cid, json.loads(body)

    def rpc(self, tok, method, params=None, rid=1):
        return call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}},
                    {"Authorization": "Bearer " + tok})

    # -- discovery
    def test_metadata_documents(self):
        st, _, b = call("GET", self.base + "/.well-known/oauth-authorization-server")
        m = json.loads(b); self.assertEqual(st, 200)
        self.assertEqual(m["issuer"], PUB); self.assertEqual(m["token_endpoint"], PUB + "/token")
        self.assertEqual(m["code_challenge_methods_supported"], ["S256"])
        st, _, b = call("GET", self.base + "/.well-known/oauth-protected-resource")
        self.assertEqual(json.loads(b)["resource"], PUB + "/mcp")
        self.assertEqual(call("GET", self.base + "/.well-known/oauth-protected-resource/mcp")[0], 200)

    # -- mcp gate
    def test_mcp_without_token_is_401_with_discovery_hint(self):
        st, h, _ = call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        self.assertEqual(st, 401)
        self.assertIn(PUB + "/.well-known/oauth-protected-resource", h["WWW-Authenticate"])

    def test_mcp_bad_token_401(self):
        self.assertEqual(self.rpc("garbage", "tools/list")[0], 401)

    # -- full flow
    def test_flow_lists_tools_incl_remember_and_searches(self):
        _, tok = self.token()
        st, _, b = self.rpc(tok["access_token"], "tools/list")
        names = sorted(t["name"] for t in json.loads(b)["result"]["tools"])
        self.assertEqual(names, ["remember", "vault_read", "vault_recent", "vault_search"])
        st, _, b = self.rpc(tok["access_token"], "tools/call", {"name": "vault_search", "arguments": {"query": "keychain"}})
        self.assertIn("Auth lock fix", json.loads(b)["result"]["content"][0]["text"])

    def test_refresh_grant_works(self):
        cid, tok = self.token()
        st, _, b = call("POST", self.base + "/token", {"grant_type": "refresh_token", "refresh_token": tok["refresh_token"], "client_id": cid}, form=True)
        self.assertEqual(st, 200); self.assertEqual(self.rpc(json.loads(b)["access_token"], "tools/list")[0], 200)

    def test_notification_gets_202(self):
        _, tok = self.token()
        st, _, _ = call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"},
                        {"Authorization": "Bearer " + tok["access_token"]})
        self.assertEqual(st, 202)

    # -- remember
    def test_remember_writes_redacted_note_under_source_agent(self):
        _, tok = self.token()
        args = {"title": "Plan for the notch", "source": "chatgpt",
                "content": "We decided X. My key is sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA ok."}
        st, _, b = self.rpc(tok["access_token"], "tools/call", {"name": "remember", "arguments": args})
        self.assertFalse(json.loads(b)["result"].get("isError"))
        files = list((self.vault / "Sessions" / "chatgpt").rglob("*.md"))
        self.assertEqual(len(files), 1)
        text = files[0].read_text()
        self.assertIn("Plan for the notch", text); self.assertIn("We decided X", text)
        self.assertNotIn("sk-ant-api03-AAAA", text)
        self.rpc(tok["access_token"], "tools/call", {"name": "remember", "arguments": args}, rid=2)  # same save twice
        self.assertEqual(text.count("We decided X"), files[0].read_text().count("We decided X"))

    def test_remember_claude_source_goes_to_claude_web_and_bad_source_errors(self):
        _, tok = self.token()
        self.rpc(tok["access_token"], "tools/call", {"name": "remember", "arguments": {"title": "t", "content": "c", "source": "claude"}})
        self.assertEqual(len(list((self.vault / "Sessions" / "claude-web").rglob("*.md"))), 1)
        st, _, b = self.rpc(tok["access_token"], "tools/call", {"name": "remember", "arguments": {"title": "t", "content": "c", "source": "../x"}})
        self.assertTrue(json.loads(b)["result"]["isError"])

    def test_remember_rejects_oversize_and_empty(self):
        _, tok = self.token()
        for args in ({"title": "t", "content": "x" * 200_001, "source": "chatgpt"}, {"title": "t", "content": "  ", "source": "chatgpt"}):
            st, _, b = self.rpc(tok["access_token"], "tools/call", {"name": "remember", "arguments": args})
            self.assertTrue(json.loads(b)["result"]["isError"])

    # -- authorize hardening
    def test_register_rejects_foreign_redirect(self):
        self.assertEqual(self.register(["https://evil.example/cb"])[0], 400)

    def test_authorize_page_get_rejects_unregistered_redirect_without_redirecting(self):
        cid = json.loads(self.register()[2])["client_id"]
        q = {"response_type": "code", "client_id": cid, "redirect_uri": "https://evil.example/cb", "code_challenge": "x", "code_challenge_method": "S256"}
        st, h, _ = call("GET", self.base + "/authorize?" + urllib.parse.urlencode(q))
        self.assertEqual(st, 400); self.assertNotIn("Location", h)

    def test_authorize_page_get_renders_form_for_valid_request(self):
        cid = json.loads(self.register()[2])["client_id"]
        q = {"response_type": "code", "client_id": cid, "redirect_uri": REDIR, "code_challenge": "abc", "code_challenge_method": "S256", "state": "s"}
        st, _, b = call("GET", self.base + "/authorize?" + urllib.parse.urlencode(q))
        self.assertEqual(st, 200); self.assertIn(b"passphrase", b); self.assertIn(b"chatgpt.com", b)

    def test_plain_pkce_method_rejected(self):
        cid = json.loads(self.register()[2])["client_id"]
        q = {"response_type": "code", "client_id": cid, "redirect_uri": REDIR, "code_challenge": "abc", "code_challenge_method": "plain"}
        self.assertEqual(call("GET", self.base + "/authorize?" + urllib.parse.urlencode(q))[0], 400)

    def test_wrong_passphrase_403_and_lockout_after_five(self):
        cid = json.loads(self.register()[2])["client_id"]
        for _ in range(5): self.assertEqual(self.authorize(cid, "nope")[2][0], 403)
        self.assertEqual(self.authorize(cid, "correct horse")[2][0], 429)   # locked even for the right passphrase

    def cid(self): return json.loads(self.register()[2])["client_id"]

    def test_lockout_is_per_ip_other_clients_unaffected(self):
        cid = self.cid()
        for _ in range(5): self.assertEqual(self.authorize(cid, "nope", ip="203.0.113.5")[2][0], 403)
        self.assertEqual(self.authorize(cid, ip="203.0.113.5")[2][0], 429)   # the attacker is locked, even with the right passphrase
        self.assertEqual(self.authorize(cid, ip="198.51.100.7")[2][0], 302)  # the owner from another address is not

    def test_lockout_expires_after_ten_minutes(self):
        cid = self.cid()
        for _ in range(5): self.authorize(cid, "nope", ip="203.0.113.5")
        self.t[0] += 599; self.assertEqual(self.authorize(cid, ip="203.0.113.5")[2][0], 429)
        self.t[0] += 2;   self.assertEqual(self.authorize(cid, ip="203.0.113.5")[2][0], 302)

    def test_ipv6_addresses_in_one_slash64_share_a_counter(self):
        cid = self.cid()
        for i in range(5): self.authorize(cid, "nope", ip="2001:db8:1:2::%x" % (i + 1))     # rotating the low 64 bits does not help
        self.assertEqual(self.authorize(cid, ip="2001:db8:1:2:ffff::9")[2][0], 429)
        self.assertEqual(self.authorize(cid, ip="2001:db8:1:3::1")[2][0], 302)             # a different /64 is a different client

    def test_success_resets_that_ips_failures(self):
        cid = self.cid()
        for _ in range(4): self.authorize(cid, "nope", ip="203.0.113.5")
        self.assertEqual(self.authorize(cid, ip="203.0.113.5")[2][0], 302)
        for _ in range(4): self.assertEqual(self.authorize(cid, "nope", ip="203.0.113.5")[2][0], 403)  # count restarted from zero

    def test_token_endpoint_bad_verifier_400(self):
        cid = json.loads(self.register()[2])["client_id"]
        v, q, (st, h, _) = self.authorize(cid)
        code = urllib.parse.parse_qs(urllib.parse.urlparse(h["Location"]).query)["code"][0]
        st, _, _ = call("POST", self.base + "/token", {"grant_type": "authorization_code", "code": code, "client_id": cid,
                                                        "redirect_uri": REDIR, "code_verifier": "w" * 50}, form=True)
        self.assertEqual(st, 400)

    def test_oversize_body_413(self):
        req = urllib.request.Request(self.base + "/register", data=b"x" * (2 * 1024 * 1024), method="POST", headers={"Content-Type": "application/json"})
        try: st = OPENER.open(req, timeout=10).status
        except urllib.error.HTTPError as e: st = e.code
        except (ConnectionError, urllib.error.URLError): st = 413  # server may close early; acceptable
        self.assertEqual(st, 413)

if __name__ == "__main__": unittest.main()
