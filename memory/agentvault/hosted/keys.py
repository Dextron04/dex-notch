"""One account, one data key. It encrypts every note (see ../seal.py) and is never stored as is, only wrapped:
  - under a key made from the person's passphrase (scrypt), so only someone who knows it can open the vault from a browser;
  - under a recovery code shown once, so a forgotten passphrase is not the end of the notes;
  - under each Mac's device token and each assistant's OAuth tokens (devices.py, oauth.py), so they can work unattended and nothing else can.
A database dump, a backup or a copy of the disk therefore holds ciphertext and wrapped keys, none of which opens without the passphrase, the recovery code or a live token."""
import base64, os, secrets, sys, time
from pathlib import Path
from typing import Optional
from .. import seal
from . import ingest
from .store import Store

MIN_PASSPHRASE, MAX_PASSPHRASE = 10, 200

class KeyError_(ValueError):
    pass

def normalize_recovery(code: str) -> str: return "".join(ch for ch in (code or "").upper() if ch.isalnum())
def _by_recovery(code: str) -> bytes: return seal.kek_from_secret(normalize_recovery(code), b"recovery")
def _by_passphrase(p: str, salt: bytes) -> bytes: return seal.kek_from_passphrase(p, salt)

def new_recovery() -> str:
    raw = base64.b32encode(secrets.token_bytes(20)).decode()   # 160 bits
    return "-".join(raw[i:i + 4] for i in range(0, 32, 4))

def check_passphrase(p: str) -> str:
    if not isinstance(p, str) or len(p) < MIN_PASSPHRASE: raise KeyError_("Use at least %d characters. A few unrelated words is easiest to remember." % MIN_PASSPHRASE)
    if len(p) > MAX_PASSPHRASE: raise KeyError_("That passphrase is too long.")
    return p

def remind_unlocked(store: Store, send, public_url: str, days: int = 7, dry: bool = False) -> list:
    """Emails everyone whose vault is not locked yet, at most once in `days`. Returns the addresses (sent to, or that would be, on a dry run).
    A failed send is not recorded as sent, so the next run tries again."""
    due = store.unlocked_users("lock-vault", time.time() - days * 86400)
    if dry: return [e for _, e in due]
    sent = []
    for uid, email in due:
        try: send(email, public_url.rstrip("/") + "/account")
        except Exception as ex: print("vault reminder failed: %s" % type(ex).__name__, file=sys.stderr, flush=True); continue
        store.nudged(uid, "lock-vault"); sent.append(email)
    return sent

def migrate(vault: Path) -> int:
    """Seals every note that is still plain text, using the key set for this request. Safe to run again."""
    n = 0
    for root, _, files in os.walk(vault):
        for f in files:
            p = os.path.join(root, f)
            if f.startswith(".tmp-") or os.path.islink(p): continue
            raw = Path(p).read_bytes()
            if not seal.is_sealed(raw): seal.write_bytes(Path(p), raw); n += 1
    return n

def _install(store: Store, uid: str, key: bytes, salt: bytes, by_pass: bytes) -> str:
    code = new_recovery()
    store.put_vault_keys(uid, salt, by_pass, seal.wrap(_by_recovery(code), key))
    with ingest.user_lock(uid), seal.unlocked(key): migrate(store.user_vault(uid))
    return code

def setup_with_key(store: Store, uid: str, passphrase: str):
    """Turns encryption on for an account: (recovery code, data key). The code is shown once. Notes already stored are sealed in place.
    The key row goes in first: from then on a Mac or assistant linked before has to link again, so nothing can write plain text while the notes are being sealed."""
    check_passphrase(passphrase)
    if store.encrypted(uid): raise KeyError_("This account already has a vault passphrase.")
    key, salt = seal.new_key(), seal.new_salt()
    return _install(store, uid, key, salt, seal.wrap(_by_passphrase(passphrase, salt), key)), key

def setup(store: Store, uid: str, passphrase: str) -> str:
    return setup_with_key(store, uid, passphrase)[0]

def _by_prf(prf: str) -> bytes:
    if not isinstance(prf, str) or not 20 <= len(prf) <= 200: raise KeyError_("This passkey can't unlock notes on this device.")
    return seal.kek_from_secret(prf, b"passkey")

def setup_passkey(store: Store, uid: str, prf: str):
    """Like `setup`, with a passkey in place of the passphrase: (recovery code, data key, the key wrapped for that passkey). There is no passphrase until the person sets one."""
    kek = _by_prf(prf)
    if store.encrypted(uid): raise KeyError_("This account is already encrypted.")
    key = seal.new_key()
    return _install(store, uid, key, b"", b""), key, seal.wrap(kek, key)

def wrap_for_passkey(key: bytes, prf: str) -> bytes: return seal.wrap(_by_prf(prf), key)

def unlock_passkey(store: Store, uid: str, credential: str, prf: str) -> Optional[bytes]:
    """The data key from a passkey's PRF secret, or None."""
    row = store.passkey(credential)
    if not row or row["user_id"] != uid or not row["wrapped"]: return None
    try: return seal.unwrap(_by_prf(prf), row["wrapped"])
    except KeyError_: return None

def unlock(store: Store, uid: str, passphrase: str = "", recovery: str = "") -> Optional[bytes]:
    """The data key, or None if the passphrase (or recovery code) is wrong."""
    row = store.vault_keys(uid)
    if not row: return None
    if recovery: return seal.unwrap(_by_recovery(recovery), row["by_recovery"])
    if not row["salt"]: return None            # a vault made with a passkey has no passphrase until one is set
    if not passphrase: return None
    key = seal.unwrap(_by_passphrase(passphrase, row["salt"]), row["by_passphrase"])
    if key is not None and not seal.salt_is_current(row["salt"]): _rewrap(store, uid, key, passphrase, row)
    return key

def _rewrap(store: Store, uid: str, key: bytes, passphrase: str, old) -> None:
    """A wrap made with the old, cheaper scrypt setting is redone with the current one now that the passphrase is in hand.
    Skipped if the keys changed meanwhile (a passphrase change must never be overwritten by this); a failure just leaves the old wrap, which still opens."""
    try:
        salt = seal.new_salt()
        now = store.vault_keys(uid)
        if now and now["salt"] == old["salt"] and now["by_passphrase"] == old["by_passphrase"]:
            store.put_vault_keys(uid, salt, seal.wrap(_by_passphrase(passphrase, salt), key), now["by_recovery"])
    except Exception as ex: print("vault rewrap skipped: %s" % type(ex).__name__, file=sys.stderr, flush=True)

def change_passphrase(store: Store, uid: str, key: bytes, new: str) -> None:
    check_passphrase(new)
    row, salt = store.vault_keys(uid), seal.new_salt()
    store.put_vault_keys(uid, salt, seal.wrap(_by_passphrase(new, salt), key), row["by_recovery"])
