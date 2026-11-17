"""Passkeys (WebAuthn) with the standard library only.

Two jobs, both small:
  - sign-in: the server checks an ECDSA P-256 signature (the "ES256" every passkey on a Mac, iPhone or security key can make) over a challenge it chose;
  - unlock: the passkey's PRF secret (see keys.py) stands in for the vault passphrase. That secret never needs a signature check: holding it is the proof.
Only public values are handled here (a public key, a signature), so none of the arithmetic has to resist timing attacks.
Attestation is not requested: we do not care which maker built the authenticator, only that this key signs for this account."""
import base64, hashlib, json, secrets, struct, threading, time
from typing import Optional, Tuple
from urllib.parse import urlparse

PRF_SALT = base64.urlsafe_b64encode(hashlib.sha256(b"dex-notch vault key v1").digest()).rstrip(b"=").decode()   # the same input every time: the PRF turns it into a secret only this passkey can make

class PasskeyError(ValueError):
    pass

def b64u(b: bytes) -> str: return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def unb64u(s: str) -> bytes:
    if not isinstance(s, str) or len(s) > 20000: raise PasskeyError("bad encoding")
    try: return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    except ValueError: raise PasskeyError("bad encoding")

# ---------------------------------------------------------------- CBOR: the few shapes a passkey sends

def _cbor(d: bytes, i: int, depth: int = 0):
    if depth > 8 or i >= len(d): raise PasskeyError("bad cbor")
    ib = d[i]; major, info = ib >> 5, ib & 31; i += 1
    if info < 24: n = info
    elif info in (24, 25, 26, 27):
        w = 1 << (info - 24)
        if i + w > len(d): raise PasskeyError("bad cbor")
        n = int.from_bytes(d[i:i + w], "big"); i += w
    else: raise PasskeyError("bad cbor")
    if major == 0: return n, i
    if major == 1: return -1 - n, i
    if major in (2, 3):
        if n > 20000 or i + n > len(d): raise PasskeyError("bad cbor")
        raw = d[i:i + n]
        return (raw if major == 2 else raw.decode("utf-8", "strict")), i + n
    if major == 4:
        if n > 64: raise PasskeyError("bad cbor")
        out = []
        for _ in range(n): v, i = _cbor(d, i, depth + 1); out.append(v)
        return out, i
    if major == 5:
        if n > 64: raise PasskeyError("bad cbor")
        out = {}
        for _ in range(n):
            k, i = _cbor(d, i, depth + 1); v, i = _cbor(d, i, depth + 1); out[k] = v
        return out, i
    raise PasskeyError("bad cbor")

# ---------------------------------------------------------------- ECDSA P-256 (verify only)

_P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff
_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
_A = _P - 3
_B = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b
_G = (0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296, 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5)

def _add(p, q):
    if p is None: return q
    if q is None: return p
    (x1, y1), (x2, y2) = p, q
    if x1 == x2:
        if (y1 + y2) % _P == 0: return None
        l = (3 * x1 * x1 + _A) * pow(2 * y1, -1, _P) % _P
    else: l = (y2 - y1) * pow(x2 - x1, -1, _P) % _P
    x3 = (l * l - x1 - x2) % _P
    return x3, (l * (x1 - x3) - y1) % _P

def _mul(k, pt):
    out = None
    while k:
        if k & 1: out = _add(out, pt)
        pt = _add(pt, pt); k >>= 1
    return out

def on_curve(x: int, y: int) -> bool:
    return 0 < x < _P and 0 < y < _P and (y * y - (x * x * x + _A * x + _B)) % _P == 0

def verify_es256(pub: bytes, message: bytes, der_sig: bytes) -> bool:
    """`pub` is x||y (64 bytes). `der_sig` is the ASN.1 signature a passkey returns."""
    try:
        x, y = int.from_bytes(pub[:32], "big"), int.from_bytes(pub[32:64], "big")
        r, s = _der_sig(der_sig)
    except (ValueError, IndexError): return False
    if len(pub) != 64 or not on_curve(x, y) or not (0 < r < _N and 0 < s < _N): return False
    e, w = int.from_bytes(hashlib.sha256(message).digest(), "big"), pow(s, -1, _N)
    pt = _add(_mul(e * w % _N, _G), _mul(r * w % _N, (x, y)))
    return pt is not None and pt[0] % _N == r

def _der_sig(d: bytes) -> Tuple[int, int]:
    if len(d) > 80 or d[0] != 0x30 or d[1] != len(d) - 2: raise ValueError("der")
    out, i = [], 2
    for _ in range(2):
        if d[i] != 0x02: raise ValueError("der")
        n = d[i + 1]; out.append(int.from_bytes(d[i + 2:i + 2 + n], "big")); i += 2 + n
    if i != len(d): raise ValueError("der")
    return out[0], out[1]

# ---------------------------------------------------------------- the two checks

def _client(cdj: bytes, kind: str, challenge: str, origin: str) -> None:
    try: c = json.loads(cdj)
    except ValueError: raise PasskeyError("passkey check failed")
    if not isinstance(c, dict) or c.get("type") != kind or c.get("challenge") != challenge or c.get("origin") != origin or c.get("crossOrigin") is True:
        raise PasskeyError("passkey check failed")

def _auth_data(ad: bytes, rp_id: str) -> Tuple[int, int]:
    """(flags, sign count). Requires this site, the person present, and the person verified (Touch ID, a PIN)."""
    if len(ad) < 37 or ad[:32] != hashlib.sha256(rp_id.encode()).digest(): raise PasskeyError("passkey check failed")
    flags = ad[32]
    if not (flags & 0x01 and flags & 0x04): raise PasskeyError("passkey check failed")
    return flags, struct.unpack(">I", ad[33:37])[0]

def register(client_data_json: bytes, attestation_object: bytes, challenge: str, origin: str, rp_id: str) -> Tuple[bytes, bytes, int]:
    """(credential id, public key x||y, sign count) of a new passkey, or PasskeyError."""
    _client(client_data_json, "webauthn.create", challenge, origin)
    att, end = _cbor(attestation_object, 0)
    if end != len(attestation_object) or not isinstance(att, dict) or not isinstance(att.get("authData"), bytes): raise PasskeyError("passkey check failed")
    ad = att["authData"]; flags, count = _auth_data(ad, rp_id)
    if not flags & 0x40 or len(ad) < 55: raise PasskeyError("passkey check failed")
    n = int.from_bytes(ad[53:55], "big")
    if not 16 <= n <= 1023 or len(ad) < 55 + n: raise PasskeyError("passkey check failed")
    cred_id = ad[55:55 + n]
    key, _ = _cbor(ad, 55 + n)
    if not isinstance(key, dict) or key.get(1) != 2 or key.get(3) != -7 or key.get(-1) != 1: raise PasskeyError("this passkey type is not supported")
    x, y = key.get(-2), key.get(-3)
    if not (isinstance(x, bytes) and isinstance(y, bytes) and len(x) == len(y) == 32) or not on_curve(int.from_bytes(x, "big"), int.from_bytes(y, "big")): raise PasskeyError("passkey check failed")
    return cred_id, x + y, count

def authenticate(client_data_json: bytes, auth_data: bytes, signature: bytes, challenge: str, origin: str, rp_id: str, pub: bytes, stored_count: int) -> int:
    """The new sign count. Raises PasskeyError unless the signature over this challenge is this account's."""
    _client(client_data_json, "webauthn.get", challenge, origin)
    _, count = _auth_data(auth_data, rp_id)
    if not verify_es256(pub, auth_data + hashlib.sha256(client_data_json).digest(), signature): raise PasskeyError("passkey check failed")
    if (stored_count or count) and count <= stored_count: raise PasskeyError("passkey check failed")     # a counter that goes backwards means a cloned key (synced passkeys always say 0)
    return count

# ---------------------------------------------------------------- challenges: random, single use, short lived

class Challenges:
    TTL, CAP = 300, 5000
    def __init__(self, now=time.time): self.now, self.lock, self.items = now, threading.Lock(), {}
    def new(self, kind: str, uid: Optional[str] = None) -> str:
        c, t = secrets.token_urlsafe(32), self.now()
        with self.lock:
            for k in [k for k, v in self.items.items() if v[2] <= t]: del self.items[k]
            if len(self.items) >= self.CAP: raise PasskeyError("busy, try again in a few minutes")
            self.items[c] = (kind, uid, t + self.TTL)
        return c
    def take(self, c: str, kind: str) -> Optional[str]:
        """The user id it was issued for (None for a sign-in), consumed. PasskeyError if it is unknown, used, expired or for something else."""
        with self.lock: v = self.items.pop(c or "", None)
        if not v or v[0] != kind or v[2] <= self.now(): raise PasskeyError("passkey check failed")
        return v[1]
