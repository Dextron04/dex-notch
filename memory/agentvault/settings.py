"""Reads the notch app's settings.json (the Gemma host), so the recorder's RAG sync targets the same server.
  ~/Library/Application Support/NotchApp/settings.json
  { "gemma": { "host": "ai.example.com", "model": "…", "keychain_service": "…", "keychain_account": "…" } }
Only the host and keychain item matter here; the model name is the app's business."""
import json, re, subprocess
from pathlib import Path
from typing import Callable, Optional

DEFAULT_PATH = Path("~/Library/Application Support/NotchApp/settings.json")
_HOST = re.compile(r"[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?")

def normalize_host(s: str) -> Optional[str]:
    """A bearer token is sent to this host, so it must be a bare hostname (optionally :port). A pasted 'https://host/' is tidied."""
    h = (s or "").strip()
    if h.lower().startswith("https://"): h = h[8:]
    if h.endswith("/"): h = h[:-1]
    if not _HOST.fullmatch(h): return None
    if ":" in h and int(h.rsplit(":", 1)[1]) > 65535: return None
    return h

def load(path: Optional[Path] = None) -> Optional[dict]:
    """{host, base, keychain_service, keychain_account}, or None when the file is missing, unreadable or incomplete."""
    p = Path(path).expanduser() if path else DEFAULT_PATH.expanduser()
    try: g = json.loads(p.read_text())["gemma"]
    except (OSError, ValueError, KeyError, TypeError): return None
    host = normalize_host(g.get("host", "")) if isinstance(g, dict) else None
    if not host: return None
    return {"host": host, "base": "https://" + host,
            "keychain_service": g.get("keychain_service") or host, "keychain_account": g.get("keychain_account") or "notchapp"}


HOSTED_SERVICE, HOSTED_ACCOUNT = "dex-notch-hosted", "device-token"  # the app stores the token here; the recorder reads it

def _keychain(service: str, account: str) -> Optional[str]:
    try: p = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service, "-a", account, "-w"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError): return None
    return p.stdout.strip() or None if p.returncode == 0 else None

def load_hosted(path: Optional[Path] = None, get_token: Callable[[str, str], Optional[str]] = _keychain) -> Optional[dict]:
    """{host, base, token} when settings.json has a "hosted": {"host": …} section AND the keychain holds a device token, else None.
    `settings.json` never holds the token itself."""
    p = Path(path).expanduser() if path else DEFAULT_PATH.expanduser()
    try: h = json.loads(p.read_text())["hosted"]
    except (OSError, ValueError, KeyError, TypeError): return None
    host = normalize_host(h.get("host", "")) if isinstance(h, dict) else None
    token = get_token(HOSTED_SERVICE, HOSTED_ACCOUNT) if host else None
    return {"host": host, "base": "https://" + host, "token": token} if host and token and token.startswith("dvt_") else None
