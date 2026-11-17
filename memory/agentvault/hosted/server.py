"""Hosted HTTP front: sign-in (magic link) + OAuth endpoints + billing + MCP over streamable HTTP, one vault per user. Stdlib only."""
import json, os, sys, tempfile, threading, time, zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie
from typing import Callable, Optional
from urllib.parse import parse_qs, urlencode, urlparse
from .. import mcp_server
from ..remote.server import MAX_BODY, client_key
from ..remote.tools import REMEMBER, REMIND
from ..index import session_files
from . import billing, devices, pages, tools, ui
from .ingest import MAX_BODY as INGEST_MAX, QUOTA_BYTES, IngestError, ingest, vault_bytes
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

STATIC_TYPES = {".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".woff2": "font/woff2", ".svg": "image/svg+xml", ".png": "image/png"}
CSP = ("default-src 'none'; style-src 'self'; script-src 'self'; font-src 'self'; img-src 'self' data:; connect-src 'self'; "
       "form-action 'self' https:; base-uri 'none'; frame-ancestors 'none'")  # nothing inline, nothing from anywhere else

def make_server(store: Store, auth: Auth, public_url: str, send_mail: Callable[[str, str], None],
                stripe: Optional[billing.Stripe] = None, stripe_webhook_secret: bytes = b"", port: int = 8766, host: str = "127.0.0.1",
                now=time.time, wait_seconds: float = 25) -> ThreadingHTTPServer:
    """`send_mail(email, link)` delivers the sign-in link (see mail.py). Without `stripe`, billing is off and only the `grant` CLI can mark users paid."""
    public = public_url.rstrip("/")
    secure = "; Secure" if public.startswith("https://") else ""
    by_ip, by_email, reg_ip = Limiter(10, 3600, now), Limiter(3, 900, now), Limiter(20, 3600, now)
    by_device = Limiter(120, 60, now)  # uploads and reminder polls per device per minute
    by_user = Limiter(120, 60, now)    # MCP calls per user per minute
    exporting, export_slots = set(), threading.BoundedSemaphore(2)  # a zip of a whole vault is heavy: one per user, two at a time

    class H(BaseHTTPRequestHandler):
        server_version = "agentvault-hosted"
        def log_message(self, *a): pass  # never log URLs: they carry codes and sign-in tokens
        def log_request(self, code="-", size="-"):
            print("%s %s %s %s" % (time.strftime("%F %T"), self.command, urlparse(self.path).path, code), file=sys.stderr, flush=True)  # the path only: no query, no body, no user

        def send(self, status, body=b"", ctype="application/json", extra=None):
            if isinstance(body, (dict, list)): body = json.dumps(body).encode()
            elif isinstance(body, str): body = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
            if "Cache-Control" not in (extra or {}): self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff"); self.send_header("Referrer-Policy", "no-referrer")  # a sign-in link in the address bar must never travel as a referrer
            if ctype.startswith("text/html"): self.send_header("Content-Security-Policy", CSP)
            for k, v in (extra or {}).items(): self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD": self.wfile.write(body)

        def body(self, limit=MAX_BODY):
            n = int(self.headers.get("Content-Length") or 0)
            if n > limit:
                self.send(413, {"error": "too_large"}, extra={"Connection": "close"}); self.close_connection = True; return None
            return self.rfile.read(n)
        def form(self):
            raw = self.body()
            return None if raw is None else {k: v[0] for k, v in parse_qs(raw.decode("utf-8", "replace")).items()}
        def ip(self): return client_key(self.headers.get("CF-Connecting-IP") or self.client_address[0])  # server listens on localhost: only the tunnel reaches it
        def cookie(self):
            c = SimpleCookie(self.headers.get("Cookie") or "")
            return c[COOKIE].value if COOKIE in c else ""
        def user(self): return auth.session_user(self.cookie())
        def device(self):
            """(uid, device id) for a valid, entitled device token, else answers 401/402 itself and returns None."""
            a = self.headers.get("Authorization") or ""
            d = devices.check(store, a[7:] if a.startswith("Bearer ") else "", now())
            if not d: self.send(401, {"error": "unauthorized"}); return None
            if not store.entitled(d[0]): self.send(402, {"error": "subscription_required"}); return None
            if not by_device.allow(d[1]): self.send(429, {"error": "slow_down"}); return None
            return d
        def validate(self, q):
            c = auth.client(q.get("client_id", ""))
            if q.get("redirect_uri") not in c["redirect_uris"]: raise AuthError("redirect_uri not registered")
            if q.get("response_type") != "code": raise AuthError("response_type must be code")
            if q.get("code_challenge_method") != "S256" or not q.get("code_challenge"): raise AuthError("PKCE S256 required")
            return c
        def html(self, status, doc, extra=None): self.send(status, doc, "text/html; charset=utf-8", extra)
        def fail(self, code, message=""): self.html(code, pages.error(code, message, self.user_email()))
        def bad(self, e): return self.fail(400, str(e))
        def user_email(self):
            uid = self.user()
            return store.email(uid) if uid else None
        def static(self, rel):
            p = (ui.STATIC / rel).resolve()
            if not p.is_relative_to(ui.STATIC) or not p.is_file() or p.suffix not in STATIC_TYPES: return self.send(404, {"error": "not_found"})
            cache = "public, max-age=31536000, immutable" if p.suffix in (".css", ".js", ".woff2") else "public, max-age=86400"   # css and js carry a version in their URL; fonts never change
            self.send(200, p.read_bytes(), STATIC_TYPES[p.suffix], {"Cache-Control": cache})
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
            if u.path == "/": return self.html(200, pages.home(self.user_email()))
            if u.path.startswith("/static/"): return self.static(u.path[8:])
            if u.path == "/privacy": return self.redirect(ui.PRIVACY)
            if u.path == "/billing/checkout": return self.checkout()
            if u.path == "/billing/portal": return self.portal()
            if u.path in ("/billing/success", "/billing/cancel"): return self.html(200, pages.billing_done(u.path.endswith("success"), self.user_email()))
            if u.path == "/login/done": return self.redirect("/account")
            if u.path == "/login": return self.redirect("/account") if self.user() else self.html(200, pages.login())
            if u.path == "/account": return self.account()
            if u.path == "/healthz":
                try: store.stats(); return self.send(200, {"ok": True})
                except Exception: return self.send(503, {"ok": False})
            if u.path == "/goodbye": return self.html(200, pages.goodbye())
            if u.path == "/v1/reminders/wait": return self.reminders_wait(q)
            if u.path == "/login/verify":  # a button, not an automatic sign-in: mail scanners that prefetch links must not burn the token
                return self.html(200, pages.verify(q.get("t", "")))
            self.fail(404)

        def do_HEAD(self):   # same headers as GET, no body (send() skips it). Not for routes that do work: a Stripe session or a held connection.
            if urlparse(self.path).path in ("/billing/checkout", "/billing/portal", "/v1/reminders/wait"): return self.send(405, b"", extra={"Allow": "GET"})
            self.do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            fn = {"/mcp": self.mcp, "/register": self.register, "/authorize": self.consent, "/token": self.token,
                  "/login": self.login, "/login/verify": self.verify, "/hooks/stripe": self.stripe_hook,
                  "/account/devices": self.add_device, "/account/devices/revoke": self.revoke_device, "/account/signout-all": self.signout_all,
                  "/logout": self.logout, "/v1/ingest": self.v1_ingest, "/account/export": self.export, "/account/delete": self.delete}.get(path)
            fn() if fn else self.send(404, {"error": "not_found"})

        def do_DELETE(self): self.send(405, {"error": "no sessions"}) if urlparse(self.path).path == "/mcp" else self.send(404, {"error": "not_found"})

        # -- sign-in
        def authorize_page(self, q):
            try: c = self.validate(q)
            except AuthError as e: return self.bad(e)
            fields = {k: q.get(k, "") for k in OAUTH_FIELDS}
            uid = self.user()
            if not uid: return self.html(200, pages.login(client_name=c["name"], fields=fields))
            if not store.entitled(uid): return self.html(402, pages.need_plan(store.email(uid), public + "/billing/checkout" if stripe else None))
            self.html(200, pages.consent(c["name"], urlparse(q["redirect_uri"]).hostname or "", store.email(uid), fields))

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
            self.html(200, pages.login_sent(email))

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
            if not uid: return self.fail(401)
            if not store.entitled(uid): return self.fail(402)
            q = {"error": "access_denied"} if f.get("decision") != "allow" else {"code": auth.issue_code(f["client_id"], uid, f["redirect_uri"], f["code_challenge"])}
            if f.get("state"): q["state"] = f["state"]
            self.redirect(f["redirect_uri"] + ("&" if "?" in f["redirect_uri"] else "?") + urlencode(q))

        # -- account page: sign-out and the Macs allowed to upload
        def account(self):
            uid = self.user()
            if not uid: return self.redirect("/login")
            vault = store.root / "data" / uid / "Vault"
            self.html(200, pages.account(email=store.email(uid), status=store.status(uid), entitled=store.entitled(uid), stripe=bool(stripe), devices=devices.listing(store, uid),
                                         mcp_url=public + "/mcp", connected=auth.connected(uid), used_bytes=vault_bytes(vault) if vault.is_dir() else 0, quota_bytes=QUOTA_BYTES,
                                         notes=len(session_files(vault)) if vault.is_dir() else 0, now=now()))

        def add_device(self):
            f = self.form()
            if f is None: return
            uid = self.user()
            if not uid: return self.fail(401)
            try: _, tok = devices.create(store, uid, f.get("name", ""))
            except ValueError as e: return self.bad(e)
            self.html(200, pages.device_token(tok, f.get("name", ""), public + "/mcp", store.email(uid)))

        def revoke_device(self):
            f = self.form()
            if f is None: return
            uid = self.user()
            if not uid: return self.fail(401)
            devices.revoke(store, uid, f.get("id", "")); self.redirect("/account")

        def export(self):
            """Everything we hold about the account as one zip: every note, plus account.json. Allowed for canceled accounts: your data is yours."""
            if self.form() is None: return
            uid = self.user()
            if not uid: return self.fail(401)
            if uid in exporting or not export_slots.acquire(blocking=False): return self.fail(429, "An export is already running. Try again in a minute.")
            exporting.add(uid)
            try:
                vault = store.root / "data" / uid / "Vault"
                with tempfile.TemporaryFile() as tmp:
                    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
                        z.writestr("account.json", json.dumps({"email": store.email(uid), "status": store.status(uid),
                            "devices": [{"name": d["name"], "added": d["created_at"]} for d in devices.listing(store, uid)]}, indent=1))
                        for root, _, files in os.walk(vault):
                            for fn in files:
                                p = os.path.join(root, fn)
                                if not os.path.islink(p): z.write(p, os.path.join("Vault", os.path.relpath(p, vault)))   # a symlink is never followed out of the vault
                    n = tmp.tell(); tmp.seek(0)
                    self.send_response(200); self.send_header("Content-Type", "application/zip"); self.send_header("Content-Length", str(n))
                    self.send_header("Content-Disposition", 'attachment; filename="dex-notch-export.zip"'); self.send_header("Cache-Control", "no-store"); self.end_headers()
                    while chunk := tmp.read(1 << 20): self.wfile.write(chunk)
            finally:
                exporting.discard(uid); export_slots.release()

        def delete(self):
            f = self.form()
            if f is None: return
            uid = self.user()
            if not uid: return self.fail(401)
            if (f.get("confirm") or "").strip().lower() != (store.email(uid) or "\0"): return self.fail(400, "Type your email address exactly to confirm.")
            sub = billing.subscription_of(store, uid)
            if stripe and sub and store.entitled(uid):  # stop the billing first; if Stripe won't confirm, keep the account so nobody is charged for nothing
                try: stripe.cancel(sub)
                except billing.BillingError: return self.fail(502, "We couldn't cancel your subscription, so nothing was deleted. Cancel it from the billing page, then try again.")
            store.delete_account(uid)
            self.redirect("/goodbye", {"Set-Cookie": "%s=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0%s" % (COOKIE, secure)})

        def logout(self):
            if self.form() is None: return
            auth.end_session(self.cookie()); self.redirect("/login", {"Set-Cookie": "%s=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0%s" % (COOKIE, secure)})

        def signout_all(self):
            if self.form() is None: return
            uid = self.user()
            if uid: auth.revoke_all(uid)
            self.redirect("/login", {"Set-Cookie": "%s=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0%s" % (COOKIE, secure)})

        # -- a Mac's recorder (device token): upload sessions, and hold a request open to be told the moment a reminder is saved
        def v1_ingest(self):
            raw = self.body(INGEST_MAX)
            if raw is None: return
            d = self.device()
            if not d: return
            try: self.send(200, ingest(store, d[0], json.loads(raw), len(raw)))
            except (IngestError, ValueError) as e: self.send(413 if "quota" in str(e) else 400, {"error": str(e)[:200]})

        def reminders_wait(self, q):
            d = self.device()
            if not d: return
            folder = store.user_vault(d[0]) / "Reminders"
            def snap():
                fs = []
                for f in sorted(folder.glob("*.md")) if folder.is_dir() else []:
                    try: fs.append((f, f.stat().st_mtime_ns))
                    except OSError: pass
                return fs, "%d:%d" % (max((m for _, m in fs), default=0), len(fs))
            after = q.get("after", "")
            try: seen = int(after.split(":")[0])
            except ValueError: seen = -1
            deadline = time.monotonic() + wait_seconds
            while True:
                fs, token = snap()
                if token != after or time.monotonic() >= deadline: break
                time.sleep(0.3)
            files = []
            if token != after:
                for f, m in fs:
                    if m > seen:
                        try: files.append({"name": f.name, "content": f.read_text(encoding="utf-8")[:4096]})
                        except OSError: pass
            self.send(200, {"token": token, "files": files})

        # -- billing
        def checkout(self):
            uid = self.user()
            if not stripe: return self.send(404, {"error": "not_found"})
            if not uid: return self.fail(401)
            if store.entitled(uid): return self.portal()
            try: self.redirect(stripe.checkout_url(uid, store.email(uid), billing.customer_of(store, uid)))
            except billing.BillingError: self.fail(502)

        def portal(self):
            uid, cus = self.user(), None
            if not stripe: return self.send(404, {"error": "not_found"})
            if not uid: return self.fail(401)
            cus = billing.customer_of(store, uid)
            if not cus: return self.fail(404, "There's no subscription on this account.")
            try: self.redirect(stripe.portal_url(cus))
            except billing.BillingError: self.fail(502)

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
            if not by_user.allow(uid): return self.send(429, {"error": "slow_down"})
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
