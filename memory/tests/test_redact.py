import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.redact import redact

SAMPLES = {
    "openai": "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcd",
    "anthropic": "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-AAAA",
    "aws": "AKIAIOSFODNN7EXAMPLE",
    "github": "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
    "google": "AIzaSyA-AbCdEfGhIjKlMnOpQrStUvWxYz01234",
    "jwt": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
    "bearer": "Authorization: Bearer abcDEF123456ghiJKL789mnoPQR",
}

class RedactTests(unittest.TestCase):
    def test_known_key_formats(self):
        for kind, sample in SAMPLES.items():
            out = redact("here is %s ok" % sample)
            self.assertIn("[redacted:%s]" % kind, out, kind)
            body = sample.split("Bearer ")[-1]
            self.assertNotIn(body, out, kind)

    def test_assignment(self):
        out = redact('password=hunter2xyz and "api_key": "abc123def456ghi789"')
        self.assertIn("password=[redacted:assignment]", out)
        self.assertIn('"api_key": "[redacted:assignment]"', out)
        self.assertNotIn("hunter2xyz", out)
        self.assertNotIn("abc123def456ghi789", out)

    def test_private_key_block(self):
        pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nabcdef\n-----END RSA PRIVATE KEY-----"
        out = redact("before\n%s\nafter" % pem)
        self.assertEqual(out, "before\n[redacted:private-key]\nafter")

    def test_keeps_non_secrets(self):
        keep = ("commit 3f786850e387550fdab836ed7e6dc881de23001b merged\n"
                "id 123e4567-e89b-12d3-a456-426614174000\n"
                "see task-list and my sky-high plan for the token economy")
        self.assertEqual(redact(keep), keep)

    def test_key_inside_url_and_code_fence(self):
        out = redact("curl https://x.io/v1?key=AIzaSyA-AbCdEfGhIjKlMnOpQrStUvWxYz01234\n```\nexport T=ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789\n```")
        self.assertNotIn("AIzaSyA", out)
        self.assertNotIn("ghp_Ab", out)
        self.assertIn("```", out)

    def test_env_style_names(self):
        cases = {"DB_PASSWORD=hunter2xyz99": "hunter2xyz99", "GITHUB_TOKEN=abcdef1234567890": "abcdef1234567890",
                 'client_secret: "abcdef1234567890"': "abcdef1234567890", '"access_token": "abcdef1234567890"': "abcdef1234567890",
                 "MY_API_KEY=abcdef1234567890": "abcdef1234567890", "AWS_SECRET_ACCESS_KEY=abcdef1234567890xyz": "abcdef1234567890xyz",
                 "N8N_API_KEY=abcdef1234567890": "abcdef1234567890"}
        for text, value in cases.items():
            out = redact(text)
            self.assertIn("[redacted:assignment]", out, text); self.assertNotIn(value, out, text)

    def test_url_and_cli_credentials(self):
        cases = [("postgres://user:pass@host/db", "user:pass"), ("curl -u bob:s3cretPw https://x.io", "bob:s3cretPw"),
                 ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "dXNlcjpwYXNzd29yZA=="),
                 ("security add-generic-password -s x -w abcdef1234567890", "abcdef1234567890")]
        for text, secret in cases: self.assertNotIn(secret, redact(text), text)

    def test_more_provider_keys(self):
        for k in ("xoxb-1234567890-abcdefghij", "sk_live_abcdefghijklmnop1234", "hf_" + "aB3dE" * 7,
                  "glpat-abcdefghij1234567890", "npm_" + "aB3dE" * 8):
            self.assertNotIn(k, redact("token for it: %s done" % k), k)

    def test_idempotent(self):
        text = "password=hunter2xyz " + SAMPLES["github"] + " " + SAMPLES["jwt"]
        once = redact(text)
        self.assertEqual(redact(once), once)

if __name__ == "__main__":
    unittest.main()
