import json, re, sys, tempfile, threading, unittest, urllib.parse
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.hosted import devices, link
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store
from test_hosted_server import PUB, call

class LinkTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.t, self.mail = Store(Path(self.d.name)), [10_000.0], []
        self.auth = Auth(self.store, now=lambda: self.t[0])
        self.srv = make_server(self.store, self.auth, PUB, lambda e, l: self.mail.append((e, l)), port=0, now=lambda: self.t[0])
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def start(self, name="Ada's MacBook"):
        st, _, body = call("POST", self.base + "/v1/link/start", {"name": name}); self.assertEqual(st, 200, body); return json.loads(body)
    def poll(self, secret): return json.loads(call("POST", self.base + "/v1/link/poll", {"secret": secret})[2])
    def sign_in_via_link(self, started, email="ada@example.com"):
        """The browser side: open the link, get the sign-in form for it, follow the mailed link, land back on /link."""
        code = started["code"].replace("-", "")
        st, _, page = call("GET", self.base + "/link?code=" + code); self.assertEqual(st, 200); self.assertIn('name="link"', page); self.assertIn("MacBook", page)
        self.assertEqual(call("POST", self.base + "/login", {"email": email, "link": code}, form=True)[0], 200)
        tok = self.mail[-1][1].split("t=")[1]
        st, h, _ = call("POST", self.base + "/login/verify", {"t": tok}, form=True)
        self.assertEqual((st, h["Location"]), (302, "/link?code=" + code))
        return {"Cookie": h["Set-Cookie"].split(";")[0]}, code

    def test_whole_flow_gives_the_app_a_device_token_once(self):
        s = self.start(); self.assertRegex(s["code"], r"^[A-Z2-9]{4}-[A-Z2-9]{4}$"); self.assertEqual(self.poll(s["secret"]), {"status": "pending"})
        ck, code = self.sign_in_via_link(s)
        self.assertIn("Add this Mac", call("GET", self.base + "/link?code=" + code, headers=ck)[2])
        self.assertEqual(self.poll(s["secret"]), {"status": "pending"})                         # opening the page approves nothing
        st, _, page = call("POST", self.base + "/link", {"code": code, "decision": "allow"}, ck, form=True); self.assertEqual(st, 200); self.assertIn("linked", page)
        got = self.poll(s["secret"]); self.assertEqual(got["status"], "approved"); self.assertEqual(got["email"], "ada@example.com"); self.assertTrue(got["token"].startswith("dvt_"))
        self.assertEqual(self.poll(s["secret"]), {"status": "expired"})                         # collected once, then gone
        uid = self.store.by_email("ada@example.com"); self.assertEqual([d["name"] for d in devices.listing(self.store, uid)], ["Ada's MacBook"])
        me = json.loads(call("GET", self.base + "/v1/me", headers={"Authorization": "Bearer " + got["token"]})[2])
        self.assertEqual((me["email"], me["status"], me["entitled"]), ("ada@example.com", "pending", False))   # confirmed without a paid plan

    def test_deny_and_a_signed_out_approve_hand_out_nothing(self):
        s = self.start(); ck, code = self.sign_in_via_link(s)
        self.assertEqual(call("POST", self.base + "/link", {"code": code, "decision": "deny"}, ck, form=True)[0], 302)
        self.assertEqual(call("POST", self.base + "/link", {"code": code, "decision": "allow"}, form=True)[0], 401)
        self.assertEqual(self.poll(s["secret"]), {"status": "pending"}); self.assertEqual(devices.listing(self.store, self.store.by_email("ada@example.com")), [])

    def test_code_is_single_use_and_expires(self):
        s = self.start(); ck, code = self.sign_in_via_link(s)
        self.assertEqual(call("POST", self.base + "/link", {"code": code, "decision": "allow"}, ck, form=True)[0], 200)
        self.assertEqual(call("POST", self.base + "/link", {"code": code, "decision": "allow"}, ck, form=True)[0], 400)   # second approval
        s2 = self.start(); self.t[0] += link.TTL + 1
        self.assertEqual(self.poll(s2["secret"]), {"status": "expired"}); self.assertEqual(call("GET", self.base + "/link?code=" + s2["code"], headers=ck)[0], 400)

    def test_a_wrong_secret_or_code_learns_nothing(self):
        s = self.start()
        self.assertEqual(self.poll("nope"), {"status": "expired"}); self.assertEqual(call("GET", self.base + "/link?code=ZZZZZZZZ")[0], 400)
        self.assertEqual(call("POST", self.base + "/login", {"email": "a@example.com", "link": "ZZZZZZZZ"}, form=True)[0], 400)
        self.assertEqual(self.poll(s["secret"]), {"status": "pending"})

    def test_me_rejects_unknown_revoked_and_deleted(self):
        s = self.start(); ck, code = self.sign_in_via_link(s); call("POST", self.base + "/link", {"code": code, "decision": "allow"}, ck, form=True)
        tok = self.poll(s["secret"])["token"]; hdr = {"Authorization": "Bearer " + tok}
        self.assertEqual(call("GET", self.base + "/v1/me")[0], 401); self.assertEqual(call("GET", self.base + "/v1/me", headers={"Authorization": "Bearer dvt_x"})[0], 401)
        uid = self.store.by_email("ada@example.com"); did = devices.listing(self.store, uid)[0]["id"]
        self.assertEqual(call("GET", self.base + "/v1/me", headers=hdr)[0], 200)
        devices.revoke(self.store, uid, did); self.assertEqual(call("GET", self.base + "/v1/me", headers=hdr)[0], 401)

    def test_deleting_the_account_removes_parked_links(self):
        s = self.start(); ck, code = self.sign_in_via_link(s); call("POST", self.base + "/link", {"code": code, "decision": "allow"}, ck, form=True)
        self.store.delete_account(self.store.by_email("ada@example.com"))
        self.assertEqual(self.poll(s["secret"]), {"status": "expired"})

    def test_code_alphabet_avoids_lookalikes_and_normalises_input(self):
        self.assertFalse(set("01OIL") & set(link.ALPHABET)); self.assertEqual(link.normalize("ab-cd 2345x"), "ABCD2345")

    def test_starting_links_is_rate_limited(self):
        codes = [call("POST", self.base + "/v1/link/start", {"name": "m"})[0] for _ in range(22)]
        self.assertEqual(codes[:20], [200] * 20); self.assertEqual(codes[20:], [429, 429])

if __name__ == "__main__": unittest.main()
