import sys, tempfile, threading, time, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentvault.hosted import keys
from agentvault.hosted.mail import smtp_sender
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store
from test_hosted_server import PUB, call

class ReminderTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail, self.vault_mail = Store(Path(self.d.name)), [], []
        self.a, self.b, self.c = (self.store.create_user(e) for e in ("a@x.io", "b@x.io", "c@x.io"))
        keys.setup(self.store, self.b, "a long enough passphrase")          # b has locked their vault
        self.store.set_status(self.c, "canceled")                           # c has left

    def test_only_live_accounts_with_an_unlocked_vault_are_asked_and_only_once_a_week(self):
        sent = []
        self.assertEqual(keys.remind_unlocked(self.store, lambda e, l: sent.append((e, l)), "https://v.example/", dry=True), ["a@x.io"]); self.assertEqual(sent, [])   # a dry run sends nothing
        self.assertEqual(keys.remind_unlocked(self.store, lambda e, l: sent.append((e, l)), "https://v.example/"), ["a@x.io"]); self.assertEqual(sent, [("a@x.io", "https://v.example/account")])
        self.assertEqual(keys.remind_unlocked(self.store, lambda e, l: sent.append((e, l)), "https://v.example"), [])                    # not again within the week
        self.assertEqual(keys.remind_unlocked(self.store, lambda e, l: sent.append((e, l)), "https://v.example", days=0), ["a@x.io"])   # but once the week is up

    def test_a_failed_send_is_tried_again_and_does_not_stop_the_rest(self):
        def boom(e, l): raise OSError("smtp down")
        self.assertEqual(keys.remind_unlocked(self.store, boom, "https://v.example"), [])
        self.assertEqual(keys.remind_unlocked(self.store, lambda e, l: None, "https://v.example"), ["a@x.io"])

    def test_locking_the_vault_stops_the_reminders_and_deleting_the_account_forgets_them(self):
        keys.remind_unlocked(self.store, lambda e, l: None, "https://v.example"); keys.setup(self.store, self.a, "another long passphrase")
        self.assertEqual(self.store.unlocked_users("lock-vault", 0), [])
        self.store.delete_account(self.a)
        with self.store.conn() as c: self.assertEqual(c.execute("SELECT COUNT(*) FROM nudges WHERE user_id=?", (self.a,)).fetchone()[0], 0)

    def test_the_email_says_what_is_paused_and_how_to_fix_it(self):
        sent = []
        class S:
            def __init__(s, *a): pass
            def __enter__(s): return s
            def __exit__(s, *a): pass
            def starttls(s, **k): pass
            def login(s, *a): pass
            def send_message(s, m): sent.append(m)
        smtp_sender("h", 587, "Dex <a@b.io>", smtp_factory=S, vault=True)("a@x.io", "https://v.example/account")
        body = sent[0].get_content(); self.assertEqual(sent[0]["Subject"], "Lock your Dex Notch vault")
        for word in ("paused", "https://v.example/account", "recovery code", "once a week"): self.assertIn(word, body)

class AdminAndBannerTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail, self.sent = Store(Path(self.d.name)), [], []
        self.srv = make_server(self.store, Auth(self.store), PUB, lambda e, l: self.mail.append((e, l)), port=0, admins=["boss@x.io"], encrypt=True, send_invite=lambda e, l: None,
                               send_vault=lambda e, l: self.sent.append((e, l)))
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def session(self, email):
        call("POST", self.base + "/login", {"email": email}, form=True); tok = self.mail[-1][1].split("t=")[1]
        _, h, _ = call("POST", self.base + "/login/verify", {"t": tok}, form=True); return {"Cookie": h["Set-Cookie"].split(";")[0]}

    def lock(self, ck): call("POST", self.base + "/account/vault", {"passphrase": "a long enough passphrase", "confirm": "a long enough passphrase", "next": "/account"}, ck, form=True)

    def test_an_unlocked_account_sees_the_setup_page_not_a_banner(self):
        ck = self.session("ada@x.io"); st, h, _ = call("GET", self.base + "/account", headers=ck); self.assertEqual((st, h["Location"].split("?")[0]), (302, "/account/setup"))
        self.lock(ck); page = call("GET", self.base + "/account", headers=ck)[2]
        self.assertNotIn("Lock your vault to keep your Mac", page); self.assertIn("1 of 5 done", page)

    def test_the_operator_can_send_the_reminders_and_nobody_else_can(self):
        # only an operator who has locked their own vault can reach the page; the reminders are for legacy accounts that are not locked yet
        self.session("ada@x.io"); boss, other = self.session("boss@x.io"), self.session("eve@x.io"); self.lock(boss); self.lock(other)
        self.assertEqual(call("POST", self.base + "/admin/vault-reminders", {}, other, form=True)[0], 404); self.assertEqual(self.sent, [])
        self.assertIn("Vaults not locked yet (1)", call("GET", self.base + "/admin", headers=boss)[2])
        self.assertEqual(call("POST", self.base + "/admin/vault-reminders", {}, boss, form=True)[0], 302)
        self.assertEqual(sorted(e for e, _ in self.sent), ["ada@x.io"])
        call("POST", self.base + "/admin/vault-reminders", {}, boss, form=True); self.assertEqual(len(self.sent), 1)      # a second press sends nothing more

if __name__ == "__main__": unittest.main()
