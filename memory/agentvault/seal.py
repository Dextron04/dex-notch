"""Encryption of notes at rest, with nothing but the standard library (the hosted service has no third-party dependencies).

Construction: keyed BLAKE2b is a PRF, so it makes a counter-mode keystream; each 64 KiB chunk carries its own BLAKE2b MAC (encrypt-then-MAC) that binds the
file nonce, the chunk's position and whether it is the last one, so chunks cannot be swapped, reordered or cut off. A file is MAGIC + nonce + chunks.
Reading only the first chunk (a note's header) is possible and still verified.

Keys: each account has one random data key. It is never stored as is: it is wrapped (sealed) under a key made from the person's passphrase, under a
recovery code, and, while a Mac or an assistant is connected, under that credential's own token. The server keeps only wrapped copies and unwraps one
for the length of a request. See hosted/keys.py.

Files written while no key is set are plain text as before, so the Mac recorder and the personal connector are unchanged."""
import contextlib, contextvars, hashlib, hmac, os, secrets, tempfile
from pathlib import Path

MAGIC = b"DXE1"
CHUNK = 65536
TAG = 16
HEAD = len(MAGIC) + 16
_key = contextvars.ContextVar("dex_data_key", default=None)

class Locked(Exception):
    """A sealed file was read with no key (or the wrong one)."""

def _sub(key: bytes, label: bytes) -> bytes:
    return hashlib.blake2b(label, key=key, digest_size=32).digest()

def _xor(data: bytes, ks: bytes) -> bytes:
    return (int.from_bytes(data, "big") ^ int.from_bytes(ks[:len(data)], "big")).to_bytes(len(data), "big") if data else b""

def _stream(enc: bytes, nonce: bytes, idx: int, n: int) -> bytes:
    pre = nonce + idx.to_bytes(8, "big")
    return b"".join(hashlib.blake2b(pre + c.to_bytes(4, "big"), key=enc, digest_size=64).digest() for c in range((n + 63) // 64))

def _tag(mac: bytes, nonce: bytes, idx: int, last: bool, ct: bytes) -> bytes:
    return hashlib.blake2b(nonce + idx.to_bytes(8, "big") + (b"\1" if last else b"\0") + ct, key=mac, digest_size=TAG).digest()

def new_key() -> bytes:
    return secrets.token_bytes(32)

def seal(key: bytes, data: bytes) -> bytes:
    enc, mac, nonce = _sub(key, b"enc"), _sub(key, b"mac"), secrets.token_bytes(16)
    parts, n = [MAGIC, nonce], max(1, -(-len(data) // CHUNK))
    for i in range(n):
        pt = data[i * CHUNK:(i + 1) * CHUNK]
        ct = _xor(pt, _stream(enc, nonce, i, len(pt)))
        parts += [ct, _tag(mac, nonce, i, i == n - 1, ct)]
    return b"".join(parts)

def is_sealed(raw: bytes) -> bool:
    return raw[:4] == MAGIC

def unseal(key: bytes, raw: bytes, first_only: bool = False) -> bytes:
    """Raises Locked when the key is wrong or the file was altered, cut short or rearranged. first_only: just the first chunk (still verified)."""
    if not is_sealed(raw) or len(raw) < HEAD + TAG: raise Locked("not a sealed file")
    enc, mac, nonce, body = _sub(key, b"enc"), _sub(key, b"mac"), raw[4:HEAD], raw[HEAD:]
    full, out, i, pos = CHUNK + TAG, [], 0, 0
    while pos < len(body):
        piece = body[pos:pos + full]
        last = pos + full >= len(body)
        ct, tag = piece[:-TAG], piece[-TAG:]
        if len(piece) < TAG or not hmac.compare_digest(tag, _tag(mac, nonce, i, last, ct)): raise Locked("wrong key or damaged file")
        out.append(_xor(ct, _stream(enc, nonce, i, len(ct))))
        i, pos = i + 1, pos + full
        if first_only: break
    return b"".join(out)

# ---- the key for this request: set by the server after it has unwrapped the caller's key, read by the note reader and writer
@contextlib.contextmanager
def unlocked(key):
    t = _key.set(key)
    try: yield
    finally: _key.reset(t)

def current():
    return _key.get()

def read_bytes(path, head: bool = False) -> bytes:
    """The file's content, decrypted if it is sealed. head: only the first chunk (enough for a note's header)."""
    with open(path, "rb") as f: raw = f.read(HEAD + CHUNK + TAG) if head else f.read()
    if not is_sealed(raw): return raw[:CHUNK] if head else raw
    k = _key.get()
    if k is None: raise Locked("this note is encrypted and no key is available")
    return unseal(k, raw, first_only=head)

def read_text(path, head: bool = False) -> str:
    return read_bytes(path, head).decode("utf-8", "replace")

def write_bytes(path: Path, data: bytes) -> None:
    """Atomic. Sealed when a key is set for this request, plain otherwise."""
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    k = _key.get()
    with tempfile.NamedTemporaryFile("wb", dir=path.parent, prefix=".tmp-", delete=False) as f:
        f.write(seal(k, data) if k is not None else data)
    os.replace(f.name, path)

# ---- wrapping one key under another (a passphrase, a recovery code, a token)
def wrap(kek: bytes, key: bytes) -> bytes: return seal(kek, key)

def unwrap(kek: bytes, blob: bytes):
    try: return unseal(kek, blob)
    except Locked: return None

def kek_from_passphrase(passphrase: str, salt: bytes) -> bytes:
    return hashlib.scrypt(passphrase.encode("utf-8"), salt=salt, n=2 ** 15, r=8, p=1, maxmem=64 * 1024 * 1024, dklen=32)

def kek_from_secret(secret: str, purpose: bytes) -> bytes:
    """For long random secrets (a token, a recovery code), where a fast hash is enough. `purpose` keeps one use from standing in for another."""
    return hashlib.blake2b(secret.encode(), key=b"dex-kek-v1", person=purpose[:16], digest_size=32).digest()
