"""HTTP front for the remote connector: OAuth endpoints + MCP over streamable HTTP (plain JSON responses). Stdlib only."""
import hmac, html, ipaddress, json, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse
from .. import mcp_server
from .oauth import OAuthError, OAuthStore
from .tools import REMEMBER, remember

MAX_BODY = 1024 * 1024
MAX_FAILS, LOCK_SECONDS, MAX_TRACKED = 5, 600, 10_000

def client_key(ip: str) -> str:
    """Who a failed login counts against: the address, or the /64 for IPv6 (one subscriber owns a whole /64, so rotating inside it must not dodge the lock)."""
    try:
        a = ipaddress.ip_address(ip.strip())
        return str(ipaddress.ip_network("%s/64" % a, strict=False)) if a.version == 6 else str(a)
    except ValueError:
        return "unknown"

def make_server(vault: Path, store: OAuthStore, passphrase: str, public_url: str, port: int = 8765, host: str = "127.0.0.1",
                now=time.time) -> ThreadingHTTPServer:
    vault, public = Path(vault), public_url.rstrip("/")
    guard = {}  # client key -> [failures, locked_until]; in memory on purpose: a restart clears locks, not security

    def tool_call(name: str, args: dict):
        return remember(vault, args) if name == "remember" else None

    class H(BaseHTTPRequestHandler):
        server_version = "agentvault"
        def log_message(self, *a): pass  # never log URLs: they carry codes

        # -- plumbing
        def send(self, status, body=b"", ctype="application/json", extra=None):
            if isinstance(body, (dict, list)): body = json.dumps(body).encode()
            elif isinstance(body, str): body = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for k, v in (extra or {}).items(): self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD": self.wfile.write(body)

        def body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_BODY:
                self.send(413, {"error": "too_large"}, extra={"Connection": "close"}); self.close_connection = True; return None
            return self.rfile.read(n)

        def form(self):
            raw = self.body()
            return None if raw is None else {k: v[0] for k, v in parse_qs(raw.decode("utf-8", "replace")).items()}

        # -- routes
        def do_GET(self):
            u = urlparse(self.path)
            if u.path.startswith("/.well-known/oauth-protected-resource"):
                return self.send(200, {"resource": public + "/mcp", "authorization_servers": [public], "bearer_methods_supported": ["header"]})
            if u.path.startswith("/.well-known/oauth-authorization-server"):
                return self.send(200, {"issuer": public, "authorization_endpoint": public + "/authorize", "token_endpoint": public + "/token",
                    "registration_endpoint": public + "/register", "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code", "refresh_token"], "code_challenge_methods_supported": ["S256"],
                    "token_endpoint_auth_methods_supported": ["none"], "scopes_supported": ["vault"]})
            if u.path == "/authorize":
                q = {k: v[0] for k, v in parse_qs(u.query).items()}
                try: return self.send(200, self.page(self.validate(q), q), "text/html; charset=utf-8")
                except OAuthError as e: return self.send(400, "Invalid request: %s" % html.escape(str(e)), "text/plain")
            self.send(404, {"error": "not_found"})

        def do_POST(self):
            path = urlparse(self.path).path
            if path == "/mcp": return self.mcp()
            if path == "/register": return self.register()
            if path == "/authorize": return self.consent()
            if path == "/token": return self.token()
            self.send(404, {"error": "not_found"})

        def do_DELETE(self): self.send(405, {"error": "no sessions"}) if urlparse(self.path).path == "/mcp" else self.send(404, {"error": "not_found"})

        # -- mcp
        def mcp(self):
            raw = self.body()
            if raw is None: return
            tok = (self.headers.get("Authorization") or "")[7:] if (self.headers.get("Authorization") or "").startswith("Bearer ") else ""
            if not store.check(tok):
                return self.send(401, {"error": "unauthorized"}, extra={"WWW-Authenticate": 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource"' % public})
            try: req = json.loads(raw)
            except ValueError: return self.send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            extra = ([REMEMBER], tool_call)
            batch = req if isinstance(req, list) else [req]
            out = [r for r in (mcp_server.handle(x, vault, extra) for x in batch if isinstance(x, dict)) if r is not None]
            if not out: return self.send(202)
            self.send(200, out if isinstance(req, list) else out[0])

        # -- oauth
        def register(self):
            raw = self.body()
            if raw is None: return
            try:
                d = json.loads(raw)
                cid = store.register(d.get("redirect_uris") or [], d.get("client_name") or "client")
            except (OAuthError, ValueError, AttributeError) as e:
                return self.send(400, {"error": "invalid_redirect_uri", "error_description": str(e)})
            self.send(201, {"client_id": cid, "client_name": d.get("client_name"), "redirect_uris": d["redirect_uris"],
                            "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]})

        def validate(self, q):
            c = store.client(q.get("client_id", ""))
            if q.get("redirect_uri") not in c["redirect_uris"]: raise OAuthError("redirect_uri not registered")
            if q.get("response_type") != "code": raise OAuthError("response_type must be code")
            if q.get("code_challenge_method") != "S256" or not q.get("code_challenge"): raise OAuthError("PKCE S256 required")
            return c

        def page(self, client, q):
            fields = "".join('<input type="hidden" name="%s" value="%s">' % (k, html.escape(q.get(k, ""), True))
                             for k in ("response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state"))
            host = html.escape(urlparse(q["redirect_uri"]).hostname or "")
            return ("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Authorize</title>"
                    "<body style='font:16px Georgia,serif;background:#000;color:#eee;max-width:26rem;margin:15vh auto;padding:0 1rem'>"
                    "<h2 style='font-weight:400'>Let <b>%s</b> read and add to your memory?</h2><p style='color:#999'>Redirects to %s</p>"
                    "<form method=post>%s<input type=password name=passphrase placeholder=passphrase autofocus required "
                    "style='width:100%%;padding:.7rem;font-size:1rem;background:#111;color:#eee;border:1px solid #444'>"
                    "<button style='margin-top:1rem;padding:.7rem 1.2rem;background:#ffb059;border:0;font-size:1rem'>Allow</button></form>"
                    % (html.escape(client["name"]), host, fields))

        def consent(self):
            f = self.form()
            if f is None: return
            try: self.validate(f)
            except OAuthError as e: return self.send(400, "Invalid request: %s" % html.escape(str(e)), "text/plain")
            t = now()
            # Cloudflare sets CF-Connecting-IP; the server listens on localhost only, so only the tunnel can reach it
            key = client_key(self.headers.get("CF-Connecting-IP") or self.client_address[0])
            for k in [k for k, (_, until) in guard.items() if until and until <= t]: del guard[k]  # expired locks
            if len(guard) >= MAX_TRACKED: guard.clear()  # bounded memory under a flood of spoofed-looking sources
            fails, until = guard.get(key, [0, 0.0])
            if until > t: return self.send(429, "Too many attempts. Try again later.", "text/plain")
            if not hmac.compare_digest(f.get("passphrase", "").encode(), passphrase.encode()):
                fails += 1
                guard[key] = [0, t + LOCK_SECONDS] if fails >= MAX_FAILS else [fails, 0.0]
                return self.send(403, "Wrong passphrase.", "text/plain")
            guard.pop(key, None)
            code = store.issue_code(f["client_id"], f["redirect_uri"], f["code_challenge"])
            q = {"code": code}
            if f.get("state"): q["state"] = f["state"]
            self.send(302, b"", "text/plain", {"Location": f["redirect_uri"] + ("&" if "?" in f["redirect_uri"] else "?") + urlencode(q)})

        def token(self):
            f = self.form()
            if f is None: return
            try:
                g = f.get("grant_type")
                if g == "authorization_code": t = store.exchange(f.get("code", ""), f.get("client_id", ""), f.get("redirect_uri", ""), f.get("code_verifier", ""))
                elif g == "refresh_token": t = store.refresh(f.get("refresh_token", ""), f.get("client_id", ""))
                else: return self.send(400, {"error": "unsupported_grant_type"})
            except OAuthError: return self.send(400, {"error": "invalid_grant"})
            self.send(200, t)

    srv = ThreadingHTTPServer((host, port), H)
    srv.daemon_threads = True
    return srv
