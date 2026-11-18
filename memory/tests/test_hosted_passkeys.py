import hashlib, json, os, secrets, struct, sys, tempfile, threading, unittest, urllib.parse
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentvault import seal
from agentvault.hosted import keys, webauthn as w
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store
from test_hosted_server import PUB, call
from test_hosted_devices import sess

RP, ORIGIN = "hosted.example.test", PUB

# ---- a software passkey: what a Mac's Touch ID does, with the same maths the server checks
def cbor(v):
    def head(major, n): return bytes([major << 5 | n]) if n < 24 else bytes([major << 5 | 24, n]) if n < 256 else bytes([major << 5 | 25]) + n.to_bytes(2, "big")
    if isinstance(v, int): return head(0, v) if v >= 0 else head(1, -1 - v)
    if isinstance(v, bytes): return head(2, len(v)) + v
    if isinstance(v, str): return head(3, len(v.encode())) + v.encode()
    if isinstance(v, dict): return head(5, len(v)) + b"".join(cbor(k) + cbor(x) for k, x in v.items())
    raise TypeError(v)

class Passkey:
    def __init__(self):
        self.d, self.cred, self.count = secrets.randbelow(w._N - 1) + 1, secrets.token_bytes(32), 0
        self.x, self.y = w._mul(self.d, w._G)
    @property
    def id(self): return w.b64u(self.cred)
    def _cdj(self, kind, challenge, origin=ORIGIN): return json.dumps({"type": kind, "challenge": challenge, "origin": origin}).encode()
    def create(self, challenge, origin=ORIGIN, flags=0x45):
        cose = cbor({1: 2, 3: -7, -1: 1, -2: self.x.to_bytes(32, "big"), -3: self.y.to_bytes(32, "big")})
        ad = hashlib.sha256(RP.encode()).digest() + bytes([flags]) + struct.pack(">I", 0) + bytes(16) + len(self.cred).to_bytes(2, "big") + self.cred + cose
        return {"clientDataJSON": w.b64u(self._cdj("webauthn.create", challenge, origin)), "attestationObject": w.b64u(cbor({"fmt": "none", "attStmt": {}, "authData": ad}))}
    def get(self, challenge, origin=ORIGIN, bump=1):
        self.count += bump
        ad = hashlib.sha256(RP.encode()).digest() + bytes([0x05]) + struct.pack(">I", self.count)
        cdj = self._cdj("webauthn.get", challenge, origin)
        e = int.from_bytes(hashlib.sha256(ad + hashlib.sha256(cdj).digest()).digest(), "big")
        while True:
            k = secrets.randbelow(w._N - 1) + 1; r = w._mul(k, w._G)[0] % w._N
            s = pow(k, -1, w._N) * (e + r * self.d) % w._N
            if r and s: break
        def i(n): b = n.to_bytes((n.bit_length() + 7) // 8, "big"); b = b"\0" + b if b[0] & 0x80 else b; return b"\x02" + bytes([len(b)]) + b
        body = i(r) + i(s)
        return {"id": self.id, "clientDataJSON": w.b64u(cdj), "authenticatorData": w.b64u(ad), "signature": w.b64u(b"\x30" + bytes([len(body)]) + body)}

class SignatureTests(unittest.TestCase):
    PUB = bytes.fromhex("471c3e758c4904285bba7e53118ed0f524adeb0757d25bd2f8e7b0d76dfa714cdd520f7aca8a8b917acc37f51de8f0c9bbe3ad858382e702dc25a12d09f7a858")
    SIG = bytes.fromhex("3046022100f42e7f88c3a7100aba59833ef912a03b61d4e22a64cf6a9d7ad115d50e637c430221008148b2e9275a2c233903442b94f63c8f9a42af81d529de39e12996bf621f2ecc")

    def test_a_signature_made_by_another_implementation_verifies(self):      # produced offline with the `cryptography` package
        self.assertTrue(w.verify_es256(self.PUB, b"dex notch known answer", self.SIG))
    def test_changes_to_message_key_or_signature_are_refused(self):
        m = b"dex notch known answer"
        self.assertFalse(w.verify_es256(self.PUB, m + b".", self.SIG))
        self.assertFalse(w.verify_es256(self.PUB[:-1] + b"\x59", m, self.SIG))
        self.assertFalse(w.verify_es256(self.PUB, m, self.SIG[:-1] + b"\xcd"))
        self.assertFalse(w.verify_es256(self.PUB, m, b"\x30\x00")); self.assertFalse(w.verify_es256(b"", m, self.SIG)); self.assertFalse(w.verify_es256(bytes(64), m, self.SIG))
    def test_the_software_passkey_agrees_with_the_verifier(self):
        p = Passkey(); a = p.get("c"); self.assertTrue(w.verify_es256(p.x.to_bytes(32, "big") + p.y.to_bytes(32, "big"),
            w.unb64u(a["authenticatorData"]) + hashlib.sha256(w.unb64u(a["clientDataJSON"])).digest(), w.unb64u(a["signature"])))
    def test_hostile_cbor_does_not_crash_or_loop(self):
        for bad in (b"", b"\xff", b"\xa1", b"\x9f\x9f\x9f", b"\xa5" * 40, b"\x5f", b"\x61"): 
            with self.assertRaises(w.PasskeyError): w._cbor(bad, 0)

class PasskeyServerTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail = Store(Path(self.d.name)), []
        self.srv = make_server(self.store, Auth(self.store), PUB, lambda e, l: self.mail.append((e, l)), port=0, encrypt=True)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def j(self, path, body=None, ck=None, method="POST"): 
        st, h, b = call(method, self.base + path, body or {}, ck); 
        try: return st, h, json.loads(b)
        except ValueError: return st, h, b
    def form(self, path, body, ck=None): return call("POST", self.base + path, body, ck, form=True)
    def session(self, email="ada@example.com"):
        self.form("/login", {"email": email}); tok = self.mail[-1][1].split("t=")[1]
        _, h, _ = self.form("/login/verify", {"t": tok}); return {"Cookie": h["Set-Cookie"].split(";")[0]}
    def enroll(self, ck, pk, prf, setup=True, origin=ORIGIN, **extra):
        st, _, o = self.j("/webauthn/register/options", ck=ck); self.assertEqual(st, 200)
        body = dict(pk.create(o["publicKey"]["challenge"], origin), prf=prf, setup=setup, next="/account", **extra)
        return self.j("/webauthn/register/finish", body, ck)
    def sign_in(self, pk, prf="", fields=None, origin=ORIGIN, bump=1):
        st, _, o = self.j("/webauthn/login/options"); self.assertEqual(st, 200)
        a = pk.get(o["publicKey"]["challenge"], origin, bump); a.update(prf=prf, fields=fields or {})
        return self.j("/webauthn/login/finish", a)
    def prf(self): return w.b64u(secrets.token_bytes(32))

    def test_a_touch_sets_up_the_vault_and_the_recovery_code_is_shown_once(self):
        ck, pk, prf = self.session(), Passkey(), self.prf()
        st, _, r = self.enroll(ck, pk, prf); self.assertEqual((st, r["next"]), (200, "/account/vault/recovery"))
        uid = self.store.by_email("ada@example.com"); self.assertTrue(self.store.encrypted(uid)); self.assertEqual(self.store.vault_keys(uid)["salt"], b"")   # no passphrase
        st, _, page = self.j("/account/vault/recovery", ck=ck, method="GET"); self.assertIn("recovery-code", page)
        st, h, _ = self.j("/account/vault/recovery", ck=ck, method="GET"); self.assertEqual((st, h["Location"]), (302, "/account"))                        # gone after one look
        self.assertIsNone(keys.unlock(self.store, uid, "anything at all"))                                                                                 # nothing to guess

    def test_one_touch_signs_in_and_opens_the_vault_for_a_mac(self):
        ck, pk, prf = self.session(), Passkey(), self.prf(); self.enroll(ck, pk, prf)
        st, h, r = self.sign_in(pk, prf); self.assertEqual((st, r["next"]), (200, "/account"))
        new = {"Cookie": h["Set-Cookie"].split(";")[0]}
        s = json.loads(call("POST", self.base + "/v1/link/start", {"name": "Mac"})[2]); code = s["code"].replace("-", "")
        page = call("GET", self.base + "/link?code=" + code, headers=new)[2]; self.assertNotIn('name="passphrase"', page)                                   # already open: nothing to type
        st, _, body = self.form("/link", {"code": code, "decision": "allow"}, new); self.assertEqual(st, 200, body)
        tok = json.loads(call("POST", self.base + "/v1/link/poll", {"secret": s["secret"]})[2])["token"]
        st, _, b = call("POST", self.base + "/v1/ingest", {"sessions": [sess("s1")]}, {"Authorization": "Bearer " + tok}); self.assertEqual(st, 200, b)
        for root, _, fs in os.walk(self.store.root / "data"): 
            for f in fs: self.assertTrue((Path(root) / f).read_bytes().startswith(seal.MAGIC))

    def test_signing_in_without_the_secret_signs_in_but_leaves_the_vault_shut(self):
        ck, pk, prf = self.session(), Passkey(), self.prf(); self.enroll(ck, pk, prf)
        st, h, r = self.sign_in(pk, ""); self.assertEqual(st, 200)
        new = {"Cookie": h["Set-Cookie"].split(";")[0]}; s = self.j("/v1/link/start", {"name": "Mac"})[2]
        page = call("GET", self.base + "/link?code=" + s["code"].replace("-", ""), headers=new)[2]; self.assertIn('name="passphrase"', page)
        self.assertEqual(self.form("/link", {"code": s["code"].replace("-", ""), "decision": "allow"}, new)[0], 200)
        self.assertEqual(self.j("/v1/link/poll", {"secret": s["secret"]})[2]["status"], "pending")                                                        # nothing approved

    def test_the_passkey_secret_can_stand_in_for_the_passphrase_on_a_magic_link_session(self):
        ck, pk, prf = self.session(), Passkey(), self.prf(); self.enroll(ck, pk, prf)
        other = self.session()                                                                                        # a fresh email-link session: shut
        s = self.j("/v1/link/start", {"name": "Mac"})[2]; code = s["code"].replace("-", "")
        bad = self.form("/link", {"code": code, "decision": "allow", "credential": pk.id, "prf": self.prf()}, other)[2]; self.assertIn("didn&#x27;t unlock", bad)
        self.assertEqual(self.form("/link", {"code": code, "decision": "allow", "credential": pk.id, "prf": prf}, other)[0], 200)
        self.assertEqual(self.j("/v1/link/poll", {"secret": s["secret"]})[2]["status"], "approved")

    def test_forged_replayed_wrong_site_and_cloned_assertions_are_refused(self):
        ck, pk, prf = self.session(), Passkey(), self.prf(); self.enroll(ck, pk, prf)
        self.assertEqual(self.sign_in(Passkey())[0], 404)                                                              # an unknown passkey: the page tells the password manager
        self.assertEqual(self.sign_in(pk, origin="https://evil.example")[0], 400)                                      # signed for another site
        st, _, o = self.j("/webauthn/login/options"); a = pk.get(o["publicKey"]["challenge"]); a.update(prf="", fields={})
        self.assertEqual(self.j("/webauthn/login/finish", a)[0], 200); self.assertEqual(self.j("/webauthn/login/finish", a)[0], 400)   # a challenge works once
        st, _, o = self.j("/webauthn/login/options"); a = pk.get(o["publicKey"]["challenge"]); a["signature"] = w.b64u(b"\x30\x06\x02\x01\x01\x02\x01\x01"); a.update(prf="", fields={})
        self.assertEqual(self.j("/webauthn/login/finish", a)[0], 400)                                                  # a bad signature
        pk.count = 0; self.assertEqual(self.sign_in(pk, bump=0)[0], 400)                                               # the counter went backwards: a copy of the key
        pk.count = 5; self.assertEqual(self.sign_in(pk)[0], 200)                                                      # and a genuine, later one still works

    def test_registration_checks_who_is_asking_and_what_was_signed(self):
        ck, other = self.session(), self.session("bob@example.com")
        st, _, o = self.j("/webauthn/register/options", ck=ck); pk = Passkey(); body = dict(pk.create(o["publicKey"]["challenge"]), prf=self.prf(), setup=True, next="/account")
        self.assertEqual(self.j("/webauthn/register/finish", body, other)[0], 400)                                     # a challenge issued to someone else
        self.assertEqual(self.enroll(ck, Passkey(), self.prf(), origin="https://evil.example")[0], 400)
        self.assertEqual(self.j("/webauthn/register/finish", body)[0], 401)                                            # no session
        st, _, o = self.j("/webauthn/register/options", ck=ck); self.assertEqual(self.j("/webauthn/register/finish", dict(Passkey().create(o["publicKey"]["challenge"], flags=0x41), prf=self.prf(), setup=True), ck)[0], 400)   # no user verification
        self.assertEqual(self.store.passkeys(self.store.by_email("ada@example.com")), [])

    def test_json_only_and_rate_limited(self):
        st, _, _ = call("POST", self.base + "/webauthn/login/options", {"x": 1}, form=True); self.assertEqual(st, 415)   # a form from another site can't post this
        codes = {self.j("/webauthn/login/options")[0] for _ in range(70)}; self.assertIn(429, codes)

    def test_removing_the_only_way_in_is_blocked_until_there_is_a_passphrase(self):
        ck, pk, prf = self.session(), Passkey(), self.prf(); self.enroll(ck, pk, prf)
        self.assertIn("Set a vault passphrase first", self.form("/account/passkeys/remove", {"id": pk.id}, ck)[2]); self.assertEqual(len(self.store.passkeys(self.store.by_email("ada@example.com"))), 1)
        _, h, _ = self.sign_in(pk, prf); new = {"Cookie": h["Set-Cookie"].split(";")[0]}
        self.form("/account/vault/passphrase", {"new": "now there is a passphrase"}, new)                              # an unlocked session may set one
        self.assertEqual(self.form("/account/passkeys/remove", {"id": pk.id}, new)[0], 302); self.assertEqual(self.store.passkeys(self.store.by_email("ada@example.com")), [])
        uid = self.store.by_email("ada@example.com"); self.assertIsNotNone(keys.unlock(self.store, uid, "now there is a passphrase"))

    def test_a_second_passkey_on_an_encrypted_account_needs_the_vault_open(self):
        ck, pk, prf = self.session(), Passkey(), self.prf(); self.enroll(ck, pk, prf)
        _, h, _ = self.sign_in(pk, prf); new = {"Cookie": h["Set-Cookie"].split(";")[0]}
        pk2, prf2 = Passkey(), self.prf(); self.assertEqual(self.enroll(new, pk2, prf2, setup=False)[0], 200)
        shut = self.session(); self.assertEqual(self.enroll(shut, Passkey(), self.prf(), setup=False)[0], 400)           # a shut session can't add one that opens the notes
        self.assertEqual(self.sign_in(pk2, prf2)[0], 200)
        uid = self.store.by_email("ada@example.com"); self.assertTrue(keys.unlock_passkey(self.store, uid, pk2.id, prf2)); self.assertIsNone(keys.unlock_passkey(self.store, uid, pk2.id, prf))

    def test_a_stolen_unlocked_cookie_cannot_export_and_unlocked_sessions_are_short(self):
        ck, pk, prf = self.session(), Passkey(), self.prf(); self.enroll(ck, pk, prf)
        _, h, _ = self.sign_in(pk, prf); new = {"Cookie": h["Set-Cookie"].split(";")[0]}
        self.assertIn("isn&#x27;t right", self.form("/account/export", {}, new)[2])                                  # the open session is not enough: export asks again
        with self.store.conn() as c: exps = [r[0] for r in c.execute("SELECT exp - ? FROM sessions WHERE wrapped IS NOT NULL", (__import__("time").time(),))]
        self.assertTrue(exps and all(e <= 12 * 3600 + 5 for e in exps))

    def test_the_security_contact_is_published(self):
        st, _, body = call("GET", self.base + "/.well-known/security.txt"); self.assertEqual(st, 200); self.assertIn("security/advisories/new", body)

    def test_deleting_the_account_removes_its_passkeys(self):
        ck, pk = self.session(), Passkey(); self.enroll(ck, pk, self.prf()); uid = self.store.by_email("ada@example.com"); self.store.delete_account(uid)
        self.assertIsNone(self.store.passkey(pk.id)); self.assertEqual(self.sign_in(pk)[0], 404)

if __name__ == "__main__": unittest.main()
