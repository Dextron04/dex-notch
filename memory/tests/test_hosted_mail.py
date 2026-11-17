import sys, tempfile, threading, unittest, urllib.parse, urllib.request
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import argparse
from agentvault.hosted.__main__ import build_sender, smtp_args
from agentvault.hosted.mail import smtp_sender
from agentvault.hosted.oauth import Auth, AuthError
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store

class FakeSMTP:
    log = []
    def __init__(self, host, port): self.log.append(("connect", host, port))
    def __enter__(self): return self
    def __exit__(self, *a): self.log.append(("quit",))
    def starttls(self, context=None): self.log.append(("starttls", context is not None and context.verify_mode.name))
    def login(self, u, p): self.log.append(("login", u, p))
    def send_message(self, m): self.log.append(("send", m))

class MailTests(unittest.TestCase):
    def setUp(self): FakeSMTP.log = []

    def test_message_and_order(self):
        smtp_sender("smtp.test", 587, "Dex <login@x.io>", "apikey", "pw", FakeSMTP)("a@x.io", "https://h.test/login/verify?t=abc")
        kinds = [e[0] for e in FakeSMTP.log]
        self.assertEqual(kinds, ["connect", "starttls", "login", "send", "quit"])          # TLS before the password, always
        self.assertEqual(FakeSMTP.log[1][1], "CERT_REQUIRED")
        m = FakeSMTP.log[3][1]
        self.assertEqual((m["From"], m["To"], m["Subject"]), ("Dex <login@x.io>", "a@x.io", "Your sign-in link"))
        self.assertIn("https://h.test/login/verify?t=abc", m.get_content()); self.assertIn("15 minutes", m.get_content())

    def test_no_login_without_user(self):
        smtp_sender("smtp.test", 25, "l@x.io", smtp_factory=FakeSMTP)("a@x.io", "https://h.test/l")
        self.assertNotIn("login", [e[0] for e in FakeSMTP.log])

    def test_header_injection_is_refused(self):
        send = smtp_sender("smtp.test", 587, "l@x.io", smtp_factory=FakeSMTP)
        with self.assertRaises(ValueError): send("a@x.io\r\nBcc: evil@x.io", "https://h.test/l")
        self.assertNotIn("send", [e[0] for e in FakeSMTP.log])
        with tempfile.TemporaryDirectory() as d, self.assertRaises(AuthError): Auth(Store(Path(d))).start_login("a@x.io\r\nBcc: evil@x.io")

    def test_mail_failure_is_invisible_to_the_visitor_and_does_not_log_the_link(self):
        def boom(email, link): raise OSError("smtp down " + link)
        with tempfile.TemporaryDirectory() as d:
            store = Store(Path(d)); srv = make_server(store, Auth(store), "https://h.test", boom, port=0)
            threading.Thread(target=srv.serve_forever, daemon=True).start(); self.addCleanup(srv.server_close); self.addCleanup(srv.shutdown)
            import io, contextlib; err = io.StringIO()
            with contextlib.redirect_stderr(err):
                r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:%d/login" % srv.server_address[1], data=urllib.parse.urlencode({"email": "a@x.io"}).encode(), method="POST"), timeout=10)
                body = r.read().decode()
            self.assertEqual(r.status, 200); self.assertIn("Check your email", body)
            self.assertIn("OSError", err.getvalue()); self.assertNotIn("login/verify", err.getvalue()); self.assertNotIn("smtp down", err.getvalue())

class CliTests(unittest.TestCase):
    def args(self, *a):
        p = argparse.ArgumentParser(); smtp_args(p); return p.parse_args(list(a))

    def test_build_sender(self):
        self.assertIsNone(build_sender(self.args()))                                                         # no SMTP host: the dev fallback
        with self.assertRaisesRegex(SystemExit, "mail-from"): build_sender(self.args("--smtp-host", "smtp.test"))
        with self.assertRaisesRegex(SystemExit, "can't read"): build_sender(self.args("--smtp-host", "smtp.test", "--mail-from", "a@x.io", "--smtp-password-file", "/nonexistent/key"))
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "k"; f.write_text("\n")
            with self.assertRaisesRegex(SystemExit, "empty"): build_sender(self.args("--smtp-host", "smtp.test", "--mail-from", "a@x.io", "--smtp-password-file", str(f)))
            f.write_text("re_secret\n")
            self.assertTrue(callable(build_sender(self.args("--smtp-host", "smtp.test", "--smtp-port", "465", "--smtp-user", "resend", "--mail-from", "Dex <l@x.io>", "--smtp-password-file", str(f)))))

if __name__ == "__main__": unittest.main()
