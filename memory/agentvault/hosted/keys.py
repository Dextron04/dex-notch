"""One account, one data key. It encrypts every note (see ../seal.py) and is never stored as is, only wrapped:
  - under a key made from the person's passphrase (scrypt), so only someone who knows it can open the vault from a browser;
  - under a recovery code shown once, so a forgotten passphrase is not the end of the notes;
  - under each Mac's device token and each assistant's OAuth tokens (devices.py, oauth.py), so they can work unattended and nothing else can.
A database dump, a backup or a copy of the disk therefore holds ciphertext and wrapped keys, none of which opens without the passphrase, the recovery code or a live token."""
import base64, os, secrets
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

def setup(store: Store, uid: str, passphrase: str) -> str:
    """Turns encryption on for an account and returns its recovery code (shown once). Notes already stored are sealed in place.
    The key row goes in first: from then on a Mac or assistant linked before has to link again, so nothing can write plain text while the notes are being sealed."""
    check_passphrase(passphrase)
    if store.encrypted(uid): raise KeyError_("This account already has a vault passphrase.")
    key, salt, code = seal.new_key(), secrets.token_bytes(16), new_recovery()
    store.put_vault_keys(uid, salt, seal.wrap(_by_passphrase(passphrase, salt), key), seal.wrap(_by_recovery(code), key))
    with ingest.user_lock(uid), seal.unlocked(key): migrate(store.user_vault(uid))
    return code

def unlock(store: Store, uid: str, passphrase: str = "", recovery: str = "") -> Optional[bytes]:
    """The data key, or None if the passphrase (or recovery code) is wrong."""
    row = store.vault_keys(uid)
    if not row: return None
    if recovery: return seal.unwrap(_by_recovery(recovery), row["by_recovery"])
    return seal.unwrap(_by_passphrase(passphrase or "", row["salt"]), row["by_passphrase"]) if passphrase else None

def change_passphrase(store: Store, uid: str, key: bytes, new: str) -> None:
    check_passphrase(new)
    row, salt = store.vault_keys(uid), secrets.token_bytes(16)
    store.put_vault_keys(uid, salt, seal.wrap(_by_passphrase(new, salt), key), row["by_recovery"])
