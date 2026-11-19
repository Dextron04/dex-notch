"""One tester's whole journey, against a real local server and the real recorder upload code:
waitlist -> invitation -> sign-in -> vault -> Mac -> upload -> Claude and ChatGPT -> save and find a memory -> delete."""
import json, os, sys, tempfile, threading, unittest, urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentvault import hosted_sync, seal
from agentvault.model import SessionMeta, Turn
from agentvault.notes import add_turns
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store
from test_hosted_server import CHALLENGE, PUB, REDIR, VERIFIER, call

PASS = "a long enough passphrase"

class BetaFlowTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail, self.invites, self.welcomes = Store(Path(self.d.name) / "server"), [], [], []
        self.srv = make_server(self.store, Auth(self.store, invite_only=True, max_users=5), PUB, lambda e, l: self.mail.append((e, l)), port=0, admins=["boss@x.io"], encrypt=True,
                               send_invite=lambda e, l: self.invites.append((e, l)), send_welcome=lambda e, l: self.welcomes.append((e, l)))
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def form(self, path, body, ck=None): return call("POST", self.base + path, body, ck, form=True)
    def session(self, email):
        self.form("/login", {"email": email}); tok = self.mail[-1][1].split("t=")[1]
        _, h, _ = self.form("/login/verify", {"t": tok}); return {"Cookie": h["Set-Cookie"].split(";")[0]}
    def connect_assistant(self, ck, name):
        cid = json.loads(call("POST", self.base + "/register", {"redirect_uris": [REDIR], "client_name": name})[2])["client_id"]
        q = {"response_type": "code", "client_id": cid, "redirect_uri": REDIR, "code_challenge": CHALLENGE, "code_challenge_method": "S256", "decision": "allow", "passphrase": PASS}
        st, h, body = self.form("/authorize", q, ck); self.assertEqual(st, 302, body)
        code = urllib.parse.parse_qs(urllib.parse.urlparse(h["Location"]).query)["code"][0]
        return json.loads(call("POST", self.base + "/token", {"grant_type": "authorization_code", "code": code, "client_id": cid, "redirect_uri": REDIR, "code_verifier": VERIFIER}, form=True)[2])["access_token"]
    def tool(self, token, name, args):
        r = json.loads(call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}, {"Authorization": "Bearer " + token})[2])
        return r["result"]["content"][0]["text"]
    def me(self, tok): return json.loads(call("GET", self.base + "/v1/me", headers={"Authorization": "Bearer " + tok})[2])

    def test_a_strangers_first_hour(self):
        # 1. a stranger finds the site, is not in yet, and asks for an invitation
        self.assertIn("closed beta", self.form("/login", {"email": "ada@example.com"})[2]); self.assertEqual(self.mail, [])
        self.assertEqual(self.form("/waitlist", {"email": "ada@example.com", "note": "I use Claude Code all day"})[0], 200)
        self.assertEqual([w["email"] for w in self.store.waitlist()], ["ada@example.com"])
        # 2. you invite them from the operator page; the email says what to do, in order
        self.store.create_user("boss@x.io"); boss = self.session("boss@x.io")
        self.form("/account/vault", {"passphrase": PASS, "confirm": PASS, "next": "/account"}, boss)          # the operator has to lock their own vault first, like anyone
        self.assertEqual(self.form("/admin/invite", {"email": "ada@example.com"}, boss)[0], 302)
        (to, _), = self.invites
        self.assertEqual(to, "ada@example.com")
        # 3. they sign in by emailed link; the account exists and the welcome email goes out
        ada = self.session("ada@example.com"); uid = self.store.by_email("ada@example.com")
        self.assertEqual([e for e, _ in self.welcomes], ["ada@example.com"])
        # 4. nothing opens before the vault is locked: the account page sends them to the setup page
        st, h, _ = call("GET", self.base + "/account", headers=ada); self.assertEqual((st, h["Location"].split("?")[0]), (302, "/account/setup"))
        self.assertIn("Create a passkey", call("GET", self.base + "/account/setup?next=/account", headers=ada)[2])
        # 5. they lock the vault and are handed a recovery code
        self.assertIn("recovery-code", self.form("/account/vault", {"passphrase": PASS, "confirm": PASS, "next": "/account"}, ada)[2])
        self.assertIn("1 of 5 done", call("GET", self.base + "/account", headers=ada)[2])
        # 6. Dex Notch asks to link this Mac; the browser approves with the passphrase
        s = json.loads(call("POST", self.base + "/v1/link/start", {"name": "Ada's MacBook"})[2]); code = s["code"].replace("-", "")
        page = call("GET", self.base + "/link?code=" + code, headers=ada)[2]
        self.assertNotIn('name="passphrase"', page); self.assertIn("Add this Mac", page)                    # they just typed it: not asked again
        self.assertEqual(self.form("/link", {"code": code, "decision": "allow"}, ada)[0], 200)
        token = json.loads(call("POST", self.base + "/v1/link/poll", {"secret": s["secret"]})[2])["token"]
        self.assertEqual(self.me(token)["progress"], {"uploaded": False, "used": False, "saved": False})
        # 7. the recorder (the real upload code) sends a conversation from the Mac's vault
        vault = Path(self.d.name) / "Vault"
        add_turns(vault, SessionMeta("claude-code", "sess-1", "my-api", "/work/my-api", "2026-11-17T10:00:00Z", "Rate limiting the API", "x"),
                  [Turn("user", "How should we rate limit the billing endpoint?", "2026-11-17T10:00:01Z"), Turn("assistant", "Use a token bucket per account, 20 per minute.", "2026-11-17T10:00:02Z")])
        self.assertEqual(hosted_sync.push(vault, self.base, token)["turns"], 2)
        me = self.me(token); self.assertTrue(me["progress"]["uploaded"]); self.assertTrue(me["vault_locked"])
        for root, _, fs in os.walk(self.store.root / "data" / uid):
            for f in fs: self.assertTrue((Path(root) / f).read_bytes().startswith(seal.MAGIC), f)         # nothing readable on the server's disk
        # 8. they connect Claude and ChatGPT
        claude, chatgpt = self.connect_assistant(ada, "Claude"), self.connect_assistant(ada, "ChatGPT")
        self.assertEqual(self.me(token)["assistants"], {"claude": True, "chatgpt": True, "codex": False})
        # 9. their first conversation: Claude saves something, ChatGPT finds it, and both can see the Claude Code session
        self.assertIn("Saved", self.tool(claude, "remember", {"title": "Trying Dex Memory", "content": "My favorite color is amber.", "source": "claude"}))
        found = self.tool(chatgpt, "vault_search", {"query": "favorite color"}); self.assertIn("Trying Dex Memory", found)
        self.assertIn("token bucket", self.tool(chatgpt, "vault_read", {"path": json.loads(self.tool(chatgpt, "vault_search", {"query": "token bucket"}))[0]["path"]}))
        # 10. the checklist is complete
        done = self.me(token)["progress"]; self.assertEqual(done, {"uploaded": True, "used": True, "saved": True})
        self.assertIn("5 of 5 done", call("GET", self.base + "/account", headers=ada)[2])
        # 11. a reminder said to an assistant reaches the Mac
        self.assertIn("Reminder set", self.tool(claude, "remind", {"text": "stand up", "when": (datetime.now(timezone.utc) + timedelta(days=1)).isoformat(), "source": "claude"}))
        r = json.loads(call("GET", self.base + "/v1/reminders/wait?after=", headers={"Authorization": "Bearer " + token})[2]); self.assertIn("stand up", r["files"][0]["content"])
        # 12. they can leave: the export needs the passphrase and the account erases everything
        self.assertIn("to continue", self.form("/account/export", {}, ada)[2])
        self.assertEqual(self.form("/account/delete", {"confirm": "ada@example.com"}, ada)[0], 302)
        self.assertFalse((self.store.root / "data" / uid).exists()); self.assertIsNone(self.store.by_email("ada@example.com"))
        self.assertEqual(call("GET", self.base + "/v1/me", headers={"Authorization": "Bearer " + token})[0], 401)

if __name__ == "__main__": unittest.main()
