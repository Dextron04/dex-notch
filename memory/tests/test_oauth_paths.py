import base64, hashlib, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.remote.oauth import OAuthStore, OAuthError
from agentvault.hosted.oauth import redirect_ok

GOOD = ["https://claude.ai/api/mcp/auth_callback", "https://claude.com/api/mcp/auth_callback", "https://chatgpt.com/connector_platform_oauth_redirect",
        "https://chatgpt.com/connector/oauth/AbC_d-9", "https://chatgpt.com/connector/oauth/" + "a" * 64]
BAD = ["https://claude.ai/", "https://claude.ai/api/mcp/auth_callback/x", "https://claude.ai/api/mcp/auth_callback?x=1", "https://claude.ai/api/mcp/auth_callback#f",
       "https://claude.ai/api/mcp/auth_callback;a", "https://claude.ai/cb", "https://chatgpt.com/cb", "https://chatgpt.com/connector/oauth/", "https://chatgpt.com/connector/oauth/a/b",
       "https://chatgpt.com/connector/oauth/" + "a" * 65, "https://chatgpt.com/connector/oauth/a.b", "https://chatgpt.com/connector/oauth/a%2Fb", "https://chatgpt.com/connector/oauth/a\n",
       "https://claude.ai/connector/oauth/abc", "https://chatgpt.com/api/mcp/auth_callback", "https://chatgpt.com/connector_platform_oauth_redirect/"]

def challenge():
    return base64.urlsafe_b64encode(hashlib.sha256(b"v" * 50).digest()).rstrip(b"=").decode()

class ExactCallbackPathTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.s = OAuthStore(Path(self.d.name) / "oauth.json")

    def test_only_the_assistants_own_return_paths_register(self):
        for u in GOOD: self.assertTrue(self.s.register([u], "x"), u)
        for u in BAD:
            with self.assertRaises(OAuthError, msg=u): self.s.register([u], "x")

    def test_a_stored_client_with_another_path_cannot_get_a_code_but_good_ones_can(self):
        self.s.s["clients"]["c_old"] = {"redirect_uris": ["https://claude.ai/cb", GOOD[3]], "name": "old"}
        with self.assertRaises(OAuthError): self.s.issue_code("c_old", "https://claude.ai/cb", challenge())
        self.assertTrue(self.s.issue_code("c_old", GOOD[3], challenge()))

    def test_hosted_redirect_ok_uses_the_same_rule_and_keeps_loopback(self):
        for u in GOOD: self.assertTrue(redirect_ok([u], u), u)
        for u in BAD: self.assertFalse(redirect_ok([u], u), u)      # registered before the path rule: still refused
        self.assertTrue(redirect_ok(["http://127.0.0.1:1111/callback"], "http://127.0.0.1:2222/callback"))

if __name__ == "__main__": unittest.main()
