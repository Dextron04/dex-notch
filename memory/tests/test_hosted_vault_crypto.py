import io, json, os, sys, tempfile, threading, unittest, urllib.parse, zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from agentvault import seal
from agentvault.hosted import devices, ingest, keys
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store
from test_hosted_server import CHALLENGE, PUB, REDIR, VERIFIER, call
from test_hosted_devices import sess

PASS = "correct horse battery"
EMAIL = "ada@example.com"

class SealTests(unittest.TestCase):
    def test_round_trip_at_every_chunk_boundary(self):
        k = seal.new_key()
        for n in (0, 1, 65535, 65536, 65537, 200_000):
            d = os.urandom(n); self.assertEqual(seal.unseal(k, seal.seal(k, d)), d, n)

    def test_wrong_key_flipped_bits_truncation_and_reordering_are_all_refused(self):
        k, d = seal.new_key(), os.urandom(200_000); s = seal.seal(k, d)
        self.assertEqual(seal.unseal(k, s, first_only=True), d[:65536])
        step = 65536 + 16
        swapped = s[:20] + s[20 + step:20 + 2 * step] + s[20:20 + step] + s[20 + 2 * step:]
        for bad in (s[:-1], s[:-step], s[:30] + bytes([s[30] ^ 1]) + s[31:], swapped, s[:20]):
            with self.assertRaises(seal.Locked): seal.unseal(k, bad)
        with self.assertRaises(seal.Locked): seal.unseal(seal.new_key(), s)

    def test_nothing_readable_in_a_sealed_file_and_two_seals_differ(self):
        k = seal.new_key(); a, b = seal.seal(k, b"secret pineapple note"), seal.seal(k, b"secret pineapple note")
        self.assertNotIn(b"pineapple", a); self.assertNotEqual(a, b)

    def test_plain_files_still_read_and_sealed_ones_need_a_key(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "a.md"; seal.write_bytes(p, b"plain"); self.assertEqual(p.read_bytes(), b"plain")
            k = seal.new_key()
            with seal.unlocked(k): seal.write_bytes(p, b"hidden"); self.assertEqual(seal.read_text(p), "hidden")
            self.assertNotIn(b"hidden", p.read_bytes())
            with self.assertRaises(seal.Locked): seal.read_text(p)

class EncryptedVaultTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail = Store(Path(self.d.name)), []
        self.auth = Auth(self.store)
        self.srv = make_server(self.store, self.auth, PUB, lambda e, l: self.mail.append((e, l)), port=0, encrypt=True)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def post(self, path, body, ck=None): return call("POST", self.base + path, body, ck, form=True)

    def session(self, email=EMAIL):
        self.post("/login", {"email": email}); tok = self.mail[-1][1].split("t=")[1]
        _, h, _ = self.post("/login/verify", {"t": tok}); return {"Cookie": h["Set-Cookie"].split(";")[0]}

    def start_link(self):
        return json.loads(call("POST", self.base + "/v1/link/start", {"name": "Ada's Mac"})[2])

    def lock(self, ck, passphrase=PASS, nxt="/account"):
        st, _, page = self.post("/account/vault", {"passphrase": passphrase, "confirm": passphrase, "next": nxt}, ck)
        self.assertEqual(st, 200, page); return page.split('id="recovery-code">')[1].split("<")[0] if "recovery-code" in page else page

    def link(self, ck, passphrase=PASS):
        s = self.start_link(); code = s["code"].replace("-", "")
        st, _, page = self.post("/link", {"code": code, "decision": "allow", "passphrase": passphrase}, ck)
        return page, json.loads(call("POST", self.base + "/v1/link/poll", {"secret": s["secret"]})[2])

    def upload(self, token, sid="s1", text="hello pineapple"):
        return call("POST", self.base + "/v1/ingest", sess(sid, [{"role": "user", "text": text, "ts": "2026-11-14T10:00:00Z"}]) and {"sessions": [sess(sid, [{"role": "user", "text": text, "ts": "2026-11-14T10:00:00Z"}])]},
                    {"Authorization": "Bearer " + token})

    def connector_token(self, ck, passphrase=PASS):
        cid = json.loads(call("POST", self.base + "/register", {"redirect_uris": [REDIR], "client_name": "Claude"})[2])["client_id"]
        q = {"response_type": "code", "client_id": cid, "redirect_uri": REDIR, "code_challenge": CHALLENGE, "code_challenge_method": "S256"}
        st, h, _ = self.post("/authorize", dict(q, decision="allow", passphrase=passphrase), ck)
        if st != 302: return None, cid
        code = urllib.parse.parse_qs(urllib.parse.urlparse(h["Location"]).query)["code"][0]
        return json.loads(call("POST", self.base + "/token", {"grant_type": "authorization_code", "code": code, "client_id": cid, "redirect_uri": REDIR, "code_verifier": VERIFIER}, form=True)[2]), cid

    def mcp(self, token, name, args):
        r = json.loads(call("POST", self.base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}, {"Authorization": "Bearer " + token})[2])
        return r["result"]["content"][0]["text"]

    def files(self):
        uid = self.store.by_email(EMAIL); return [Path(r, f) for r, _, fs in os.walk(self.store.root / "data" / uid / "Vault") for f in fs]

    def test_a_new_account_has_to_lock_its_vault_before_linking_a_mac(self):
        ck = self.session(); s = self.start_link(); code = s["code"].replace("-", "")
        st, h, _ = call("GET", self.base + "/link?code=" + code, headers=ck)
        self.assertEqual(st, 302); self.assertTrue(h["Location"].startswith("/account/setup"))
        self.assertEqual(self.post("/link", {"code": code, "decision": "allow"}, ck)[0], 302)       # the gate answers first; the "Lock your vault first" stop behind it never shows

    def test_notes_are_sealed_on_disk_and_open_for_the_mac_and_the_assistant(self):
        ck = self.session(); rec = self.lock(ck, nxt="/account")
        self.assertRegex(rec, r"^([A-Z2-7]{4}-){7}[A-Z2-7]{4}$")
        page, got = self.link(ck); self.assertEqual(got["status"], "approved"); tok = got["token"]
        st, _, body = self.upload(tok); self.assertEqual(st, 200, body)
        fs = self.files(); self.assertTrue(fs)
        for f in fs: self.assertTrue(f.read_bytes().startswith(seal.MAGIC), f); self.assertNotIn(b"pineapple", f.read_bytes())
        with self.assertRaises(seal.Locked): seal.read_text(fs[0])                       # the disk alone is not enough
        t, cid = self.connector_token(ck); self.assertIsNotNone(t)
        self.assertIn("pineapple", self.mcp(t["access_token"], "vault_search", {"query": "pineapple"}))
        t2 = json.loads(call("POST", self.base + "/token", {"grant_type": "refresh_token", "refresh_token": t["refresh_token"], "client_id": cid}, form=True)[2])
        self.assertIn("pineapple", self.mcp(t2["access_token"], "vault_search", {"query": "pineapple"}))   # the key follows the rotating refresh token

    def test_a_wrong_passphrase_opens_nothing_and_tries_are_limited(self):
        self.lock(self.session()); ck = self.session()          # a fresh email-link session is shut: the one that just set the passphrase stays open
        page, got = self.link(ck, "not the passphrase"); self.assertIn("isn&#x27;t right", page); self.assertEqual(got["status"], "pending")
        self.assertIsNone(self.connector_token(ck, "nope")[0])
        for _ in range(8): self.link(ck, "wrong again")
        self.assertIn("Too many", self.link(ck)[0])                                      # even the right one waits

    def test_a_mac_linked_before_encryption_has_to_link_again(self):
        uid = self.store.create_user(EMAIL); _, old = devices.create(self.store, uid, "Old Mac")
        self.assertEqual(call("GET", self.base + "/v1/me", headers={"Authorization": "Bearer " + old})[0], 200)
        keys.setup(self.store, uid, PASS)
        self.assertEqual(call("GET", self.base + "/v1/me", headers={"Authorization": "Bearer " + old})[0], 401)
        self.assertEqual(self.upload(old)[0], 401)

    def test_notes_stored_before_encryption_are_sealed_when_it_is_switched_on(self):
        uid = self.store.create_user(EMAIL); ingest.ingest(self.store, uid, {"sessions": [sess("old", [{"role": "user", "text": "old pineapple", "ts": "2026-11-14T10:00:00Z"}])]})
        self.assertIn(b"old pineapple", self.files()[0].read_bytes())
        keys.setup(self.store, uid, PASS)
        for f in self.files(): self.assertTrue(f.read_bytes().startswith(seal.MAGIC)); self.assertNotIn(b"pineapple", f.read_bytes())
        with seal.unlocked(keys.unlock(self.store, uid, PASS)): self.assertIn("old pineapple", seal.read_text(self.files()[0]))

    def test_the_database_alone_does_not_open_the_vault(self):
        ck = self.session(); self.lock(ck); self.link(ck)
        uid = self.store.by_email(EMAIL); row = self.store.vault_keys(uid)
        self.assertIsNone(keys.unlock(self.store, uid, "guess one two three")); self.assertIsNone(keys.unlock(self.store, uid, recovery="AAAA-BBBB-CCCC"))
        with self.store.conn() as c: self.assertTrue(c.execute("SELECT wrapped_key FROM devices").fetchone()[0])
        self.assertNotIn(PASS.encode(), row["by_passphrase"])

    def test_export_needs_the_passphrase_and_gives_readable_notes(self):
        ck = self.session(); self.lock(ck); _, got = self.link(ck); self.upload(got["token"])
        self.assertIn("to continue", self.post("/account/export", {}, ck)[2])
        self.assertIn("isn&#x27;t right", self.post("/account/export", {"passphrase": "wrong"}, ck)[2])
        import urllib.request
        r = urllib.request.urlopen(urllib.request.Request(self.base + "/account/export", data=urllib.parse.urlencode({"passphrase": PASS}).encode(), headers=ck), timeout=10)
        z = zipfile.ZipFile(io.BytesIO(r.read())); self.assertEqual(r.headers["Content-Type"], "application/zip")
        notes = [z.read(n) for n in z.namelist() if n.startswith("Vault/Sessions/")]
        self.assertTrue(notes); self.assertIn(b"pineapple", notes[0]); self.assertFalse(notes[0].startswith(seal.MAGIC))

    def test_recovery_code_and_changing_the_passphrase(self):
        ck = self.session(); rec = self.lock(ck); _, got = self.link(ck); self.upload(got["token"])
        uid = self.store.by_email(EMAIL)
        self.assertIsNotNone(keys.unlock(self.store, uid, recovery=rec.lower()))
        self.post("/account/vault/passphrase", {"recovery": rec, "new": "a brand new passphrase"}, ck)
        self.assertIsNone(keys.unlock(self.store, uid, PASS)); self.assertIsNotNone(keys.unlock(self.store, uid, "a brand new passphrase"))
        self.assertIn("pineapple", self.mcp(self.connector_token(ck, "a brand new passphrase")[0]["access_token"], "vault_search", {"query": "pineapple"}))   # same key, so the old notes still open

    def test_reminders_are_sealed_and_still_reach_the_mac(self):
        ck = self.session(); self.lock(ck); _, got = self.link(ck); t, _ = self.connector_token(ck)
        when = (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()
        self.assertIn("Reminder set", self.mcp(t["access_token"], "remind", {"text": "call pineapple mum", "when": when, "source": "claude"}))
        for f in self.files(): self.assertNotIn(b"pineapple", f.read_bytes())
        r = json.loads(call("GET", self.base + "/v1/reminders/wait?after=", headers={"Authorization": "Bearer " + got["token"]})[2])
        self.assertIn("call pineapple mum", r["files"][0]["content"])

    def test_deleting_the_account_removes_the_wrapped_keys(self):
        ck = self.session(); self.lock(ck); uid = self.store.by_email(EMAIL); self.store.delete_account(uid)
        self.assertFalse(self.store.encrypted(uid))

if __name__ == "__main__": unittest.main()
