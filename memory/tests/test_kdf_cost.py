import hashlib, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault import seal
from agentvault.hosted import keys
from agentvault.hosted.store import Store

PASS = "correct horse battery"

class KdfCostTests(unittest.TestCase):
    def setUp(self):
        self.store = Store(Path(tempfile.mkdtemp())); self.uid = self.store.create_user("ada@example.com")

    def test_new_wraps_use_2_17_and_record_it_with_the_salt(self):
        salt = seal.new_salt()
        self.assertEqual((len(salt), salt[16]), (17, 17))
        want = hashlib.scrypt(PASS.encode(), salt=salt[:16], n=2 ** 17, r=8, p=1, maxmem=256 * 1024 * 1024, dklen=32)
        self.assertEqual(seal.kek_from_passphrase(PASS, salt), want)
        keys.setup(self.store, self.uid, PASS)
        self.assertTrue(seal.salt_is_current(self.store.vault_keys(self.uid)["salt"]))
        self.assertIsNotNone(keys.unlock(self.store, self.uid, PASS)); self.assertIsNone(keys.unlock(self.store, self.uid, "wrong passphrase"))

    def test_a_wrap_made_with_the_old_setting_still_opens_and_is_redone_on_unlock(self):
        key, salt = seal.new_key(), b"s" * 16                     # legacy: bare 16-byte salt, N = 2^15
        old = seal.wrap(hashlib.scrypt(PASS.encode(), salt=salt, n=2 ** 15, r=8, p=1, maxmem=64 * 1024 * 1024, dklen=32), key)
        self.assertEqual(seal.kek_from_passphrase(PASS, salt), hashlib.scrypt(PASS.encode(), salt=salt, n=2 ** 15, r=8, p=1, maxmem=64 * 1024 * 1024, dklen=32))
        self.store.put_vault_keys(self.uid, salt, old, seal.wrap(keys._by_recovery("ABCD-EFGH"), key))
        self.assertIsNone(keys.unlock(self.store, self.uid, "wrong passphrase")); self.assertEqual(self.store.vault_keys(self.uid)["salt"], salt)   # a miss changes nothing
        self.assertEqual(keys.unlock(self.store, self.uid, PASS), key)
        row = self.store.vault_keys(self.uid)
        self.assertTrue(seal.salt_is_current(row["salt"]))          # redone with N = 2^17
        self.assertEqual(keys.unlock(self.store, self.uid, PASS), key)
        self.assertEqual(keys.unlock(self.store, self.uid, recovery="ABCD-EFGH"), key)             # the recovery wrap is untouched

    def test_changing_the_passphrase_uses_the_new_setting(self):
        code = keys.setup(self.store, self.uid, PASS); key = keys.unlock(self.store, self.uid, PASS)
        keys.change_passphrase(self.store, self.uid, key, "another long passphrase")
        self.assertTrue(seal.salt_is_current(self.store.vault_keys(self.uid)["salt"]))
        self.assertEqual(keys.unlock(self.store, self.uid, "another long passphrase"), key); self.assertEqual(keys.unlock(self.store, self.uid, recovery=code), key)

if __name__ == "__main__": unittest.main()
