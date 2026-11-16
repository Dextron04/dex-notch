"""Hosted HTTP front: sign-in (magic link) + OAuth endpoints + billing + MCP over streamable HTTP, one vault per user. Stdlib only."""
import html, json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie
from typing import Callable, Optional
from urllib.parse import parse_qs, urlencode, urlparse
from .. import mcp_server
from ..remote.server import MAX_BODY, client_key
from ..remote.tools import REMEMBER, REMIND
from . import billing, tools
from .oauth import SESSION_TTL, Auth, AuthError
from .store import Store

OAUTH_FIELDS = ("response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state")
COOKIE = "av_session"

class Limiter:
    """`n` events per `window` seconds per key, in memory (a restart forgets: fine for abuse control, not for security)."""
    def __init__(self, n: int, window: float, now: Callable[[], float], cap: int = 10_000):
        self.n, self.window, self.now, self.cap, self.hits = n, window, now, cap, {}
    def allow(self, key: str) -> bool:
        t = self.now()
        if len(self.hits) >= self.cap: self.hits.clear()
        h = [x for x in self.hits.get(key, []) if x > t - self.window]
        ok = len(h) < self.n
        if ok: h.append(t)
        self.hits[key] = h
        return ok

def page(title: str, body: str) -> str:
    return ("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>%s</title>"
            "<body style='font:16px Georgia,serif;background:#000;color:#eee;max-width:26rem;margin:15vh auto;padding:0 1rem'>%s"
            % (html.escape(title), body))

INPUT = "width:100%;padding:.7rem;font-size:1rem;background:#111;color:#eee;border:1px solid #444;box-sizing:border-box"
BTN = "margin-top:1rem;padding:.7rem 1.2rem;background:#ffb059;border:0;font-size:1rem;cursor:pointer"
def hidden(d: dict) -> str:
    return "".join('<input type="hidden" name="%s" value="%s">' % (html.escape(k), html.escape(v, True)) for k, v in d.items())

def make_server(store: Store, auth: Auth, public_url: str, send_mail: Callable[[str, str], None],
                stripe: Optional[billing.Stripe] = None, stripe_webhook_secret: bytes = b"", port: int = 8766, host: str = "127.0.0.1",
                now=time.time) -> ThreadingHTTPServer:
    """`send_mail(email, link)` delivers the sign-in link (see mail.py). Without `stripe`, billing is off and only the `grant` CLI can mark users paid."""
    public = public_url.rstrip("/")
    secure = "; Secure" if public.startswith("https://") else ""
    by_ip, by_email, reg_ip = Limiter(10, 3600, now), Limiter(3, 900, now), Limiter(20, 3600, now)

    class H(BaseHTTPRequestHandler):
        server_version = "agentvault-hosted"
        def log_message(self, *a): pass  # never log URLs: they carry codes and sign-in tokens

        def send(self, status, body=b"", ctype="application/json", extra=None):
            if isinstance(body, (dict, list)): body = json.dumps(body).encode()
            elif isinstance(body, str): body = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store"); self.send_header("X-Content-Type-Options", "nosniff")
            if ctype.startswith("text/html"): self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https:")
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
        def ip(self): return client_key(self.headers.get("CF-Connecting-IP") or self.client_address[0])  # server listens on localhost: only the tunnel reaches it
        def user(self):
            c = SimpleCookie(self.headers.get("Cookie") or "")
            return auth.session_user(c[COOKIE].value) if COOKIE in c else None
        def validate(self, q):
            c = auth.client(q.get("client_id", ""))
            if q.get("redirect_uri") not in c["redirect_uris"]: raise AuthError("redirect_uri not registered")
            if q.get("response_type") != "code": raise AuthError("response_type must be code")
            if q.get("code_challenge_method") != "S256" or not q.get("code_challenge"): raise AuthError("PKCE S256 required")
            return c
        def bad(self, e): return self.send(400, "Invalid request: %s" % html.escape(str(e)), "text/plain")
        def redirect(self, url, extra=None): self.send(302, b"", "text/plain", dict({"Location": url}, **(extra or {})))

        # -- routes
        def do_GET(self):
            u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
            if u.path.startswith("/.well-known/oauth-protected-resource"):
                return self.send(200, {"resource": public + "/mcp", "authorization_servers": [public], "bearer_methods_supported": ["header"]})
            if u.path.startswith("/.well-known/oauth-authorization-server"):
                return self.send(200, {"issuer": public, "authorization_endpoint": public + "/authorize", "token_endpoint": public + "/token",
                    "registration_endpoint": public + "/register", "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code", "refresh_token"], "code_challenge_methods_supported": ["S256"],
                    "token_endpoint_auth_methods_supported": ["none"], "scopes_supported": ["vault"]})
            if u.path == "/authorize": return self.authorize_page(q)
            if u.path == "/billing/checkout": return self.checkout()
            if u.path == "/billing/portal": return self.portal()
            if u.path in ("/billing/success", "/billing/cancel"):
                ok = u.path.endswith("success")
                return self.send(200, page("Billing", "<h2 style='font-weight:400'>%s</h2>" % ("Thanks. Your plan activates in a few seconds; go back to Claude or ChatGPT and connect again." if ok
                                                                                             else "No charge was made.")), "text/html; charset=utf-8")
            if u.path == "/login/done": return self.send(200, page("Signed in", "<h2 style='font-weight:400'>You're signed in</h2>"), "text/html; charset=utf-8")
            if u.path == "/login/verify":  # a button, not an automatic sign-in: mail scanners that prefetch links must not burn the token
                return self.send(200, page("Sign in", "<h2 style='font-weight:400'>Finish signing in</h2><form method=post>%s<button style='%s'>Continue</button></form>"
                                           % (hidden({"t": q.get("t", "")}), BTN)), "text/html; charset=utf-8")
            self.send(404, {"error": "not_found"})

        def do_POST(self):
            path = urlparse(self.path).path
            fn = {"/mcp": self.mcp, "/register": self.register, "/authorize": self.consent, "/token": self.token,
                  "/login": self.login, "/login/verify": self.verify, "/hooks/stripe": self.stripe_hook}.get(path)
            fn() if fn else self.send(404, {"error": "not_found"})

        def do_DELETE(self): self.send(405, {"error": "no sessions"}) if urlparse(self.path).path == "/mcp" else self.send(404, {"error": "not_found"})

        # -- sign-in
        def authorize_page(self, q):
            try: c = self.validate(q)
            except AuthError as e: return self.bad(e)
            fields = {k: q.get(k, "") for k in OAUTH_FIELDS}
            uid = self.user()
            if not uid:
                return self.send(200, page("Sign in", "<h2 style='font-weight:400'>Sign in to let <b>%s</b> use your memory</h2>"
                    "<form method=post action=/login>%s<input type=email name=email placeholder=you@example.com autofocus required style='%s'>"
                    "<button style='%s'>Email me a sign-in link</button></form>" % (html.escape(c["name"]), hidden(fields), INPUT, BTN)), "text/html; charset=utf-8")
            if not store.entitled(uid):
                link = public + "/billing/checkout" if stripe else None
                msg = ('<p><a style="color:#ffb059" href="%s">Subscribe to continue</a></p>' % html.escape(link, True)) if link else "<p style='color:#999'>Paid plans aren't open yet.</p>"
                return self.send(402, page("Subscription needed", "<h2 style='font-weight:400'>A subscription is needed first</h2>" + msg), "text/html; charset=utf-8")
            host = html.escape(urlparse(q["redirect_uri"]).hostname or "")
            self.send(200, page("Authorize", "<h2 style='font-weight:400'>Let <b>%s</b> read and add to your memory?</h2><p style='color:#999'>Redirects to %s</p>"
                "<form method=post>%s<button name=decision value=allow style='%s'>Allow</button> <button name=decision value=deny style='%s;background:#333;color:#eee'>Deny</button></form>"
                % (html.escape(c["name"]), host, hidden(fields), BTN, BTN)), "text/html; charset=utf-8")

        def login(self):
            f = self.form()
            if f is None: return
            email, nxt = (f.get("email") or "").strip().lower(), None
            if f.get("client_id"):  # sign-in started from an OAuth request: come back to it, rebuilt server side (never a URL taken from the form)
                try: self.validate(f); nxt = "/authorize?" + urlencode({k: f[k] for k in OAUTH_FIELDS if f.get(k)})
                except AuthError as e: return self.bad(e)
            # the answer never says whether the address is known, or whether a mail went out
            if by_ip.allow(self.ip()) and by_email.allow(email):
                try: send_mail(email, "%s/login/verify?t=%s" % (public, auth.start_login(email, nxt)))
                except AuthError: pass
                except Exception as e: print("sign-in mail failed: %s" % type(e).__name__, file=sys.stderr, flush=True)  # the response must not reveal it, and the link must not be logged
            self.send(200, page("Check your email", "<h2 style='font-weight:400'>Check your email</h2><p style='color:#999'>If the address is valid, a sign-in link is on its way. It works once, for 15 minutes.</p>"), "text/html; charset=utf-8")

        def verify(self):
            f = self.form()
            if f is None: return
            try: sess, _, nxt = auth.finish_login(f.get("t", ""))
            except AuthError as e: return self.bad(e)
            self.redirect(nxt if nxt and nxt.startswith("/authorize?") else "/login/done",
                          {"Set-Cookie": "%s=%s; HttpOnly; SameSite=Lax; Path=/; Max-Age=%d%s" % (COOKIE, sess, SESSION_TTL, secure)})

        def consent(self):
            f = self.form()
            if f is None: return
            try: self.validate(f)
            except AuthError as e: return self.bad(e)
            uid = self.user()
            if not uid: return self.send(401, "Sign in first.", "text/plain")
            if not store.entitled(uid): return self.send(402, "Subscription required.", "text/plain")
            q = {"error": "access_denied"} if f.get("decision") != "allow" else {"code": auth.issue_code(f["client_id"], uid, f["redirect_uri"], f["code_challenge"])}
            if f.get("state"): q["state"] = f["state"]
            self.redirect(f["redirect_uri"] + ("&" if "?" in f["redirect_uri"] else "?") + urlencode(q))

        # -- billing
        def checkout(self):
            uid = self.user()
            if not stripe: return self.send(404, {"error": "not_found"})
            if not uid: return self.send(401, "Sign in first.", "text/plain")
            if store.entitled(uid): return self.portal()
            try: self.redirect(stripe.checkout_url(uid, store.email(uid), billing.customer_of(store, uid)))
            except billing.BillingError: self.send(502, "Payments are unavailable right now. Try again shortly.", "text/plain")

        def portal(self):
            uid, cus = self.user(), None
            if not stripe: return self.send(404, {"error": "not_found"})
            if not uid: return self.send(401, "Sign in first.", "text/plain")
            cus = billing.customer_of(store, uid)
            if not cus: return self.send(404, "No subscription on this account.", "text/plain")
            try: self.redirect(stripe.portal_url(cus))
            except billing.BillingError: self.send(502, "Payments are unavailable right now. Try again shortly.", "text/plain")

        def stripe_hook(self):
            raw = self.body()
            if raw is None: return
            if not stripe_webhook_secret: return self.send(404, {"error": "not_found"})
            if not billing.verify_signature(raw, self.headers.get("Stripe-Signature") or "", stripe_webhook_secret, now()): return self.send(400, {"error": "bad_signature"})
            try: ev = json.loads(raw); assert isinstance(ev, dict) and ev.get("id")
            except (ValueError, AssertionError): return self.send(400, {"error": "bad_json"})
            try: self.send(200, {"result": billing.apply_event(store, ev)})
            except Exception: self.send(500, {"error": "retry"})  # Stripe retries with backoff; the event was not recorded

        # -- oauth
        def register(self):
            raw = self.body()
            if raw is None: return
            if not reg_ip.allow(self.ip()): return self.send(429, {"error": "slow_down"})
            try:
                d = json.loads(raw); cid = auth.register(d.get("redirect_uris") or [], d.get("client_name") or "client")
            except (AuthError, ValueError, AttributeError) as e:
                return self.send(400, {"error": "invalid_redirect_uri", "error_description": str(e)})
            self.send(201, {"client_id": cid, "client_name": d.get("client_name"), "redirect_uris": d["redirect_uris"],
                            "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]})

        def token(self):
            f = self.form()
            if f is None: return
            try:
                g = f.get("grant_type")
                if g == "authorization_code": t = auth.exchange(f.get("code", ""), f.get("client_id", ""), f.get("redirect_uri", ""), f.get("code_verifier", ""))
                elif g == "refresh_token": t = auth.refresh(f.get("refresh_token", ""), f.get("client_id", ""))
                else: return self.send(400, {"error": "unsupported_grant_type"})
            except AuthError: return self.send(400, {"error": "invalid_grant"})
            self.send(200, t)

        # -- mcp: token -> user -> entitlement -> that user's vault, in that order
        def mcp(self):
            raw = self.body()
            if raw is None: return
            a = self.headers.get("Authorization") or ""
            uid = auth.check(a[7:] if a.startswith("Bearer ") else "")
            if not uid:
                return self.send(401, {"error": "unauthorized"}, extra={"WWW-Authenticate": 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource"' % public})
            if not store.entitled(uid): return self.send(402, {"error": "subscription_required"})
            try: req = json.loads(raw)
            except ValueError: return self.send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            extra = ([REMEMBER, REMIND], lambda name, args: tools.call(store, uid, name, args))
            batch = req if isinstance(req, list) else [req]
            out = [r for r in (mcp_server.handle(x, store.user_vault(uid), extra) for x in batch if isinstance(x, dict)) if r is not None]
            if not out: return self.send(202)
            self.send(200, out if isinstance(req, list) else out[0])

    srv = ThreadingHTTPServer((host, port), H)
    srv.daemon_threads = True
    return srv
