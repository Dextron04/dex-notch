import base64, hashlib, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.remote.oauth import OAuthStore, OAuthError

REDIR = "https://claude.ai/api/mcp/auth_callback"

def pkce():
    v = "v" * 50
    return v, base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()

class OAuthTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.t = [1000.0]
        self.s = OAuthStore(Path(self.d.name) / "oauth.json", now=lambda: self.t[0])
        self.cid = self.s.register([REDIR], "Claude")

    def code(self, challenge):
        return self.s.issue_code(self.cid, REDIR, challenge)

    def test_full_flow_and_validate(self):
        v, c = pkce()
        tok = self.s.exchange(self.code(c), self.cid, REDIR, v)
        self.assertTrue(self.s.check(tok["access_token"]))
        self.assertFalse(self.s.check("nope"))
        self.assertEqual(tok["token_type"], "Bearer")

    def test_wrong_verifier_rejected(self):
        _, c = pkce()
        with self.assertRaises(OAuthError): self.s.exchange(self.code(c), self.cid, REDIR, "x" * 50)

    def test_code_is_single_use(self):
        v, c = pkce(); code = self.code(c)
        self.s.exchange(code, self.cid, REDIR, v)
        with self.assertRaises(OAuthError): self.s.exchange(code, self.cid, REDIR, v)

    def test_code_expires_after_5_minutes(self):
        v, c = pkce(); code = self.code(c); self.t[0] += 301
        with self.assertRaises(OAuthError): self.s.exchange(code, self.cid, REDIR, v)

    def test_access_token_expires_after_1_hour(self):
        v, c = pkce(); tok = self.s.exchange(self.code(c), self.cid, REDIR, v)
        self.t[0] += 3599; self.assertTrue(self.s.check(tok["access_token"]))
        self.t[0] += 2; self.assertFalse(self.s.check(tok["access_token"]))

    def test_refresh_rotates_and_old_refresh_dies(self):
        v, c = pkce(); tok = self.s.exchange(self.code(c), self.cid, REDIR, v)
        new = self.s.refresh(tok["refresh_token"], self.cid)
        self.assertTrue(self.s.check(new["access_token"]))
        with self.assertRaises(OAuthError): self.s.refresh(tok["refresh_token"], self.cid)

    def test_refresh_expires_after_30_days(self):
        v, c = pkce(); tok = self.s.exchange(self.code(c), self.cid, REDIR, v); self.t[0] += 30 * 86400 + 1
        with self.assertRaises(OAuthError): self.s.refresh(tok["refresh_token"], self.cid)

    def test_redirect_must_match_registration(self):
        with self.assertRaises(OAuthError): self.s.issue_code(self.cid, "https://evil.example/cb", pkce()[1])

    def test_register_rejects_foreign_redirect_host(self):
        with self.assertRaises(OAuthError): self.s.register(["https://evil.example/cb"], "x")
        with self.assertRaises(OAuthError): self.s.register(["http://claude.ai/cb"], "x")  # https only
        with self.assertRaises(OAuthError): self.s.register([], "x")

    def test_unknown_client_rejected(self):
        with self.assertRaises(OAuthError): self.s.issue_code("nope", REDIR, pkce()[1])

    def test_tokens_survive_restart_and_are_stored_hashed(self):
        v, c = pkce(); tok = self.s.exchange(self.code(c), self.cid, REDIR, v)
        raw = (Path(self.d.name) / "oauth.json").read_text()
        self.assertNotIn(tok["access_token"], raw); self.assertNotIn(tok["refresh_token"], raw)
        again = OAuthStore(Path(self.d.name) / "oauth.json", now=lambda: self.t[0])
        self.assertTrue(again.check(tok["access_token"]))
        self.assertEqual((Path(self.d.name) / "oauth.json").stat().st_mode & 0o777, 0o600)

    def test_exchange_binds_client(self):
        other = self.s.register([REDIR], "other"); v, c = pkce()
        with self.assertRaises(OAuthError): self.s.exchange(self.code(c), other, REDIR, v)

if __name__ == "__main__": unittest.main()
