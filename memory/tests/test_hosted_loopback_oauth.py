"""A Codex-like client signs in through the hosted server with a 127.0.0.1 redirect and a different port at authorize."""
import json, sys, unittest, urllib.parse
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_hosted_attacks import AttackTests, PASS
from test_hosted_server import CHALLENGE, VERIFIER, call
from test_hosted_devices import sess

REG, USED = "http://127.0.0.1:1111/callback/x", "http://127.0.0.1:2222/callback/x"

class LoopbackSignIn(unittest.TestCase):
    setUp = AttackTests.setUp; form = AttackTests.form; make_user = AttackTests.make_user; tool = AttackTests.tool   # the same server and users, none of its tests

    def authorize(self, cid, redirect, who="ann"):
        q = {"response_type": "code", "client_id": cid, "redirect_uri": redirect, "code_challenge": CHALLENGE, "code_challenge_method": "S256", "decision": "allow", "passphrase": PASS}
        return self.form("/authorize", q, self.users[who]["ck"])
    def token(self, cid, code, redirect):
        return call("POST", self.base + "/token", {"grant_type": "authorization_code", "code": code, "client_id": cid, "redirect_uri": redirect, "code_verifier": VERIFIER}, form=True)
    def code_from(self, h): return urllib.parse.parse_qs(urllib.parse.urlparse(h["Location"]).query)["code"][0]

    def test_sign_in_on_another_port_returns_there_and_the_token_works(self):
        call("POST", self.base + "/v1/ingest", {"sessions": [sess("s1", [{"role": "user", "text": "ann's mango plan", "ts": "2026-11-14T10:00:00Z"}])]}, self.users["ann"]["hdr"])
        cid = json.loads(call("POST", self.base + "/register", {"redirect_uris": [REG], "client_name": "Codex"})[2])["client_id"]
        st, h, _ = self.authorize(cid, USED)
        self.assertEqual(st, 302); self.assertTrue(h["Location"].startswith(USED + "?code="), h["Location"])      # the code goes back to the port it asked for
        self.assertEqual(self.token(cid, self.code_from(h), REG)[0], 400)                                         # the token call must repeat the redirect used at authorize
        st, h, _ = self.authorize(cid, USED)
        st, _, body = self.token(cid, self.code_from(h), USED); self.assertEqual(st, 200)
        self.assertIn("mango", self.tool(json.loads(body)["access_token"], "vault_search", {"query": "mango"}))

    def test_other_hosts_paths_and_schemes_get_no_code(self):
        cid = json.loads(call("POST", self.base + "/register", {"redirect_uris": [REG], "client_name": "Codex"})[2])["client_id"]
        for bad in ("http://127.0.0.1:2222/callback/y", "http://localhost:2222/callback/x", "http://evil.example:2222/callback/x", "https://127.0.0.1:2222/callback/x"):
            st, h, _ = self.authorize(cid, bad); self.assertEqual(st, 400, bad); self.assertNotIn("Location", h)

if __name__ == "__main__": unittest.main()
