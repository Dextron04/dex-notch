"""Single-owner OAuth 2.1 store for the remote connector: dynamic client registration, PKCE (S256), rotating refresh tokens.
Codes and tokens are persisted only as SHA-256 hashes (state file mode 0600)."""
import base64, hashlib, hmac, json, os, secrets, tempfile, time
from pathlib import Path
from typing import Callable, List
from urllib.parse import urlparse

CODE_TTL, ACCESS_TTL, REFRESH_TTL = 300, 3600, 30 * 86400
ALLOWED_REDIRECT_HOSTS = ("chatgpt.com", "claude.ai", "claude.com")

class OAuthError(Exception):
    pass

def plain_url(uri) -> bool:
    """No backslash, whitespace, control character or user@ part. Python's urlparse and browsers disagree on these:
    `https://evil.example\\@claude.ai/` is claude.ai to urlparse but evil.example to a browser, and CR/LF would split the Location header."""
    u = str(uri)
    if "\\" in u or any(ord(c) <= 32 or ord(c) == 127 for c in u): return False
    try: p = urlparse(u)
    except ValueError: return False
    return p.username is None and p.password is None

def https_redirect_ok(uri, allowed) -> bool:
    """An https address on one of the allowed hosts, written plainly: the host and nothing else (no port, no user@) between // and the path."""
    if not plain_url(uri): return False
    p = urlparse(str(uri))
    return p.scheme == "https" and bool(p.hostname) and p.netloc == p.hostname and p.hostname in allowed

def _h(v: str) -> str:
    return hashlib.sha256(v.encode()).hexdigest()

class OAuthStore:
    def __init__(self, path: Path, now: Callable[[], float] = time.time, allowed_hosts=ALLOWED_REDIRECT_HOSTS):
        self.path, self.now, self.allowed = Path(path), now, tuple(allowed_hosts)
        try: self.s = json.loads(self.path.read_text())
        except (OSError, ValueError): self.s = {}
        for k in ("clients", "codes", "access", "refresh"): self.s.setdefault(k, {})

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(self.path.parent), prefix=".tmp-")
        with os.fdopen(fd, "w") as f: json.dump(self.s, f)
        os.chmod(tmp, 0o600); os.replace(tmp, self.path)

    def _gc(self) -> None:
        t = self.now()
        for k in ("codes", "access", "refresh"):
            self.s[k] = {h: r for h, r in self.s[k].items() if r["exp"] > t}

    def register(self, redirect_uris: List[str], name: str) -> str:
        if not redirect_uris: raise OAuthError("redirect_uris required")
        for u in redirect_uris:
            if not https_redirect_ok(u, self.allowed): raise OAuthError("redirect_uri not allowed: %s" % u)
        cid = "c_" + secrets.token_urlsafe(16)
        self.s["clients"][cid] = {"redirect_uris": list(redirect_uris), "name": str(name)[:80]}
        self._save(); return cid

    def client(self, cid: str) -> dict:
        c = self.s["clients"].get(cid)
        if not c: raise OAuthError("unknown client")
        return c

    def issue_code(self, cid: str, redirect_uri: str, challenge: str) -> str:
        if redirect_uri not in self.client(cid)["redirect_uris"] or not plain_url(redirect_uri): raise OAuthError("redirect_uri mismatch")  # plain_url: a client registered before that check can't be used
        if not challenge: raise OAuthError("code_challenge required")
        self._gc(); code = secrets.token_urlsafe(32)
        self.s["codes"][_h(code)] = {"cid": cid, "redir": redirect_uri, "ch": challenge, "exp": self.now() + CODE_TTL}
        self._save(); return code

    def _tokens(self, cid: str) -> dict:
        a, r, t = secrets.token_urlsafe(32), secrets.token_urlsafe(32), self.now()
        self.s["access"][_h(a)] = {"cid": cid, "exp": t + ACCESS_TTL}
        self.s["refresh"][_h(r)] = {"cid": cid, "exp": t + REFRESH_TTL}
        self._save()
        return {"access_token": a, "token_type": "Bearer", "expires_in": ACCESS_TTL, "refresh_token": r}

    def exchange(self, code: str, cid: str, redirect_uri: str, verifier: str) -> dict:
        rec = self.s["codes"].pop(_h(code), None)  # single use: gone even if the checks below fail
        self._save()
        if not rec or rec["exp"] <= self.now(): raise OAuthError("invalid or expired code")
        if rec["cid"] != cid or rec["redir"] != redirect_uri: raise OAuthError("code does not match client")
        want = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        if not hmac.compare_digest(want, rec["ch"]): raise OAuthError("PKCE verification failed")
        return self._tokens(cid)

    def refresh(self, refresh_token: str, cid: str) -> dict:
        rec = self.s["refresh"].pop(_h(refresh_token), None)
        self._save()
        if not rec or rec["exp"] <= self.now() or rec["cid"] != cid: raise OAuthError("invalid refresh token")
        return self._tokens(cid)

    def check(self, access_token: str) -> bool:
        rec = self.s["access"].get(_h(access_token or ""))
        return bool(rec and rec["exp"] > self.now())
