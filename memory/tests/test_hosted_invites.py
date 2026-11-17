import sys, tempfile, threading, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_hosted_server import call, PUB
from agentvault.hosted.oauth import Auth, AuthError
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store
from agentvault.hosted.mail import smtp_sender

class InviteTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail = Store(Path(self.d.name)), []
        self.auth = Auth(self.store, invite_only=True, max_users=2)
        self.invites, self.welcomes = [], []
        self.srv = make_server(self.store, self.auth, PUB, lambda e, l: self.mail.append((e, l)), port=0, send_invite=lambda e, l: self.invites.append((e, l)), admins=["Boss@x.io"], send_welcome=lambda e, l: self.welcomes.append((e, l)))
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def login(self, email): return call("POST", self.base + "/login", {"email": email}, form=True)

    def join(self, email):
        self.login(email); tok = self.mail[-1][1].split("t=")[1]
        return call("POST", self.base + "/login/verify", {"t": tok}, form=True)[0]

    def test_uninvited_gets_no_mail_and_a_plain_message(self):
        st, _, body = self.login("stranger@x.io")
        self.assertEqual(st, 200); self.assertIn("closed beta", body); self.assertEqual(self.mail, [])

    def test_invited_can_join_and_existing_user_can_return(self):
        self.store.invite("Friend@X.io")
        self.assertEqual(self.join("friend@x.io"), 302)
        self.store.uninvite("friend@x.io")
        self.join("friend@x.io"); self.assertEqual(self.store.user_count(), 1)   # an account stays after its invite goes

    def test_invite_withdrawn_before_the_link_is_used(self):
        self.store.invite("a@x.io"); self.login("a@x.io"); tok = self.mail[-1][1].split("t=")[1]
        self.store.uninvite("a@x.io")
        self.assertEqual(call("POST", self.base + "/login/verify", {"t": tok}, form=True)[0], 400)
        self.assertIsNone(self.store.by_email("a@x.io"))

    def test_cap_stops_new_accounts_but_not_returning_ones(self):
        for e in ("a@x.io", "b@x.io", "c@x.io"): self.store.invite(e)
        self.assertEqual(self.join("a@x.io"), 302); self.assertEqual(self.join("b@x.io"), 302)
        self.assertIn("full", self.login("c@x.io")[2]); self.assertIsNone(self.auth.may_join("a@x.io"))
        self.store.join_waitlist("b@x.io"); self.store.delete_account(self.store.by_email("b@x.io"))
        self.assertEqual((self.store.waitlist(), self.store.invited("b@x.io")), ([], False))   # erasing an account erases the address everywhere
        self.assertEqual(self.join("c@x.io"), 302)  # a deleted account frees its place

class TransportTests(unittest.TestCase):
    def test_http_visitors_are_sent_to_https_and_bad_lengths_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            srv = make_server(Store(Path(d)), Auth(Store(Path(d))), PUB, lambda e, l: None, port=0)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            base = "http://127.0.0.1:%d" % srv.server_address[1]
            try:
                for m in ("GET", "POST"):
                    st, h, _ = call(m, base + "/login?x=1", {} if m == "POST" else None, {"CF-Visitor": '{"scheme":"http"}'})
                    self.assertEqual((st, h["Location"]), (308, PUB + "/login?x=1"))
                self.assertEqual(call("GET", base + "/healthz", headers={"CF-Visitor": '{"scheme":"https"}'})[0], 200)
                self.assertIn("max-age", call("GET", base + "/healthz")[1].get("Strict-Transport-Security", ""))
                self.assertEqual(call("POST", base + "/login", {}, {"Content-Length": "-5"}, form=True)[0] in (400,), True)
            finally: srv.shutdown(); srv.server_close()

class WelcomeTests(InviteTests):
    def test_welcome_goes_out_once_when_the_account_is_created(self):
        import time
        self.store.invite("new@x.io"); self.assertEqual(self.join("new@x.io"), 302); self.join("new@x.io")   # second sign-in: not new
        for _ in range(50):
            if self.welcomes: break
            time.sleep(0.05)
        self.assertEqual(self.welcomes, [("new@x.io", PUB + "/account")])

class WaitlistTests(InviteTests):
    def admin_cookie(self):
        self.store.invite("boss@x.io"); self.login("boss@x.io"); tok = self.mail[-1][1].split("t=")[1]
        return {"Cookie": call("POST", self.base + "/login/verify", {"t": tok}, form=True)[1]["Set-Cookie"].split(";")[0]}

    def test_waitlist_stores_once_and_never_invites(self):
        for _ in range(2): self.assertIn("on the list", call("POST", self.base + "/waitlist", {"email": "Hope@X.io", "note": "daily mail"}, form=True)[2])
        self.assertEqual([w["email"] for w in self.store.waitlist()], ["hope@x.io"])
        self.assertIn("closed beta", self.login("hope@x.io")[2]); self.assertEqual(self.mail, [])   # waiting is not an invitation

    def test_waitlist_rejects_bad_email_and_bots_and_floods(self):
        self.assertIn("look like an email", call("POST", self.base + "/waitlist", {"email": "nope"}, form=True)[2])
        call("POST", self.base + "/waitlist", {"email": "bot@x.io", "website": "http://spam"}, form=True); self.assertEqual(self.store.waitlist(), [])
        codes = [call("POST", self.base + "/waitlist", {"email": "u%d@x.io" % i}, form=True)[0] for i in range(8)]
        self.assertIn(429, codes)

    def test_admin_is_hidden_from_everyone_but_the_operator(self):
        self.assertEqual(call("GET", self.base + "/admin")[0], 404)
        self.store.invite("a@x.io"); self.login("a@x.io"); tok = self.mail[-1][1].split("t=")[1]
        ck = {"Cookie": call("POST", self.base + "/login/verify", {"t": tok}, form=True)[1]["Set-Cookie"].split(";")[0]}
        self.assertEqual(call("GET", self.base + "/admin", headers=ck)[0], 404)
        self.assertEqual(call("POST", self.base + "/admin/invite", {"email": "z@x.io"}, ck, form=True)[0], 404)
        self.assertFalse(self.store.invited("z@x.io"))

    def test_operator_invites_and_the_invitee_can_then_sign_in(self):
        call("POST", self.base + "/waitlist", {"email": "hope@x.io"}, form=True)
        ck = self.admin_cookie()
        self.assertIn("hope@x.io", call("GET", self.base + "/admin", headers=ck)[2])
        self.assertEqual(call("POST", self.base + "/admin/invite", {"email": "hope@x.io"}, ck, form=True)[0], 302)
        self.assertEqual(self.invites, [("hope@x.io", PUB + "/login")])
        self.assertIsNotNone(self.store.waitlist()[0]["invited_at"]); self.assertEqual(self.join("hope@x.io"), 302)
        call("POST", self.base + "/waitlist", {"email": "two@x.io"}, form=True); call("POST", self.base + "/waitlist", {"email": "three@x.io"}, form=True)
        call("POST", self.base + "/admin/invite", {"all": "1"}, ck, form=True)
        self.assertEqual(sorted(e for e, _ in self.invites), ["hope@x.io", "three@x.io", "two@x.io"])   # invite-all skips anyone already invited
        call("POST", self.base + "/admin/waitlist/remove", {"email": "two@x.io"}, ck, form=True); self.assertNotIn("two@x.io", [w["email"] for w in self.store.waitlist()])

class InviteMailTests(unittest.TestCase):
    def test_invite_mail_says_what_to_do_and_signin_mail_is_unchanged(self):
        sent = []
        class S:
            def __init__(s, *a): pass
            def __enter__(s): return s
            def __exit__(s, *a): pass
            def starttls(s, **k): pass
            def login(s, *a): pass
            def send_message(s, m): sent.append(m)
        smtp_sender("h", 587, "Dex <a@b.io>", smtp_factory=S, invite=True)("x@y.io", "https://h/login")
        smtp_sender("h", 587, "Dex <a@b.io>", smtp_factory=S)("x@y.io", "https://h/login/verify?t=1")
        smtp_sender("h", 587, "Dex <a@b.io>", smtp_factory=S, welcome=True)("x@y.io", "https://h/account")
        self.assertIn("invited", sent[0]["Subject"]); self.assertIn("x@y.io", sent[0].get_content()); self.assertEqual(sent[1]["Subject"], "Your sign-in link"); self.assertEqual(sent[2]["Subject"], "Welcome to Dex Notch"); self.assertIn("https://h/account", sent[2].get_content())

if __name__ == "__main__": unittest.main()
