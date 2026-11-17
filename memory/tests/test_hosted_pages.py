import json, re, sys, tempfile, threading, unittest, urllib.error, urllib.parse, urllib.request
from html.parser import HTMLParser
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.hosted import pages, ui
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import CSP, make_server
from agentvault.hosted.store import Store

DEVICES = [{"id": "d_1", "name": "MacBook <b>Pro</b>", "created_at": 1_700_000_000, "last_seen": 1_700_000_500}]
def all_pages():
    """Every page the service can show, with awkward input where input is shown, so escaping gets exercised."""
    evil = '<script>alert(1)</script>"\'&'
    kw = dict(email=evil + "@x.io", status="active", entitled=True, stripe=True, devices=DEVICES, mcp_url="https://h.test/mcp", connected=True, used_bytes=5_000_000, quota_bytes=524288000, notes=3)
    return {
        "home": pages.home(None), "home-signed-in": pages.home("a@x.io"),
        "login": pages.login(), "login-oauth": pages.login(client_name=evil, fields={"client_id": evil}, email=evil, error=evil),
        "sent": pages.login_sent(evil), "verify": pages.verify(evil),
        "consent": pages.consent(evil, "claude.ai", "a@x.io", {"client_id": evil}),
        "login-link": pages.login(link_name=evil, fields={"link": evil}), "link-confirm": pages.link_confirm("a@x.io", evil, "ABCD2345"), "link-done": pages.link_done(evil, "a@x.io"),
        "need-plan": pages.need_plan("a@x.io", None), "need-plan-stripe": pages.need_plan("a@x.io", "https://h.test/billing/checkout"),
        "account": pages.account(**kw), "account-pending": pages.account(**dict(kw, status="pending", entitled=False, stripe=False, devices=[], connected=False)),
        "token": pages.device_token("dvt_abc", evil, "https://h.test/mcp", "a@x.io"),
        "billing-ok": pages.billing_done(True, "a@x.io"), "billing-cancel": pages.billing_done(False, None), "goodbye": pages.goodbye(),
        **{"error-%d" % c: pages.error(c, evil if c == 400 else "") for c in (400, 401, 402, 404, 429, 502)},
    }

class Scan(HTMLParser):
    def __init__(self):
        super().__init__(); self.h1 = 0; self.ids = []; self.refs = []; self.inline = []; self.imgs = []; self.labels_for = set(); self.inputs = []; self.script = False; self.title = ""; self._t = False
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "h1": self.h1 += 1
        if "id" in a: self.ids.append(a["id"])
        for k in a:
            if k == "style" or k.startswith("on"): self.inline.append("%s[%s]" % (tag, k))
        if tag == "script" and "src" not in a: self.inline.append("inline <script>")
        if tag == "style": self.inline.append("<style>")
        if tag == "img": self.imgs.append(a)
        for k in ("src", "href"):
            if a.get(k, "").startswith("/static/"): self.refs.append(a[k])
        if tag == "label" and "for" in a: self.labels_for.add(a["for"])
        if tag == "input" and a.get("type", "text") not in ("hidden", "submit"): self.inputs.append(a)
        if tag == "title": self._t = True
    def handle_endtag(self, tag):
        if tag == "title": self._t = False
    def handle_data(self, d):
        if self._t: self.title += d

class PageContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.scans = {}; [cls.scans.__setitem__(n, (lambda s: (s.feed(h), s)[1])(Scan())) for n, h in all_pages().items()]

    def test_nothing_inline_because_the_csp_would_drop_it(self):
        for n, s in self.scans.items(): self.assertEqual(s.inline, [], n)

    def test_each_page_has_one_h1_unique_ids_a_title_and_labelled_inputs(self):
        variant_of = {"home-signed-in": "home", "login-oauth": "login", "login-link": "login", "need-plan-stripe": "need-plan", "account-pending": "account"}   # the same page in another state
        by_kind = {}
        for n, s in self.scans.items():
            self.assertEqual(s.h1, 1, n); self.assertEqual(len(s.ids), len(set(s.ids)), n); self.assertTrue(s.title.strip().endswith("Dex Notch"), n)
            for i in s.inputs: self.assertIn(i.get("id"), s.labels_for, "%s: input %r has no <label for>" % (n, i.get("name")))
            by_kind.setdefault(variant_of.get(n, n), set()).add(s.title)
        self.assertTrue(all(len(t) == 1 for t in by_kind.values()), by_kind)                                  # a page keeps its title across states
        flat = [next(iter(t)) for t in by_kind.values()]
        self.assertEqual(len(flat), len(set(flat)), "two different pages share a title")                       # and no two pages share one

    def test_images_have_alt_and_dimensions(self):
        for n, s in self.scans.items():
            for i in s.imgs: self.assertIn("alt", i, n); self.assertTrue(i.get("width") and i.get("height"), n)

    def test_user_input_is_escaped_everywhere(self):
        for n, h in all_pages().items(): self.assertNotIn("<script>alert(1)</script>", h, n)
        self.assertNotIn("<b>Pro</b>", pages.account(email="a@x.io", status="active", entitled=True, stripe=False, devices=DEVICES, mcp_url="https://h.test/mcp", connected=False, used_bytes=0, quota_bytes=1, notes=0))

    def test_apostrophes_are_not_double_escaped_in_headings(self):
        self.assertIn("Paid plans aren't open yet", pages.need_plan("a@x.io", None))

class ServerAssetTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store = Store(Path(self.d.name))
        self.srv = make_server(self.store, Auth(self.store), "https://h.test", lambda e, l: None, port=0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start(); self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def get(self, path):
        try: r = urllib.request.urlopen(self.base + path, timeout=10); return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
        except urllib.error.HTTPError as e: b = e.read(); e.close(); return e.code, {k.lower(): v for k, v in e.headers.items()}, b

    def test_home_and_every_asset_it_references_exist(self):
        st, h, body = self.get("/"); self.assertEqual(st, 200)
        s = Scan(); s.feed(body.decode())
        refs = set(s.refs) | set(re.findall(r"url\((/static/[^)]+)\)", self.get("/static/app.css?v=" + ui.VERSION)[2].decode()))
        self.assertIn("/static/app.css?v=" + ui.VERSION, refs); self.assertGreaterEqual(len(refs), 8)
        for ref in refs:
            st, hh, data = self.get(ref); self.assertEqual(st, 200, ref); self.assertGreater(len(data), 100, ref)

    def test_security_headers_on_pages(self):
        for path in ("/", "/login", "/login/verify?t=x", "/nope"):
            _, h, _ = self.get(path) if path != "/nope" else (0, self.get(path)[1], 0)
            self.assertEqual(h["content-security-policy"], CSP, path); self.assertEqual(h["referrer-policy"], "no-referrer", path); self.assertEqual(h["x-content-type-options"], "nosniff", path)
            self.assertEqual(h["cache-control"], "no-store", path)
        self.assertNotIn("'unsafe-inline'", CSP); self.assertIn("frame-ancestors 'none'", CSP)

    def test_head_matches_get_without_a_body_and_skips_routes_that_do_work(self):
        def head(path):
            try: r = urllib.request.urlopen(urllib.request.Request(self.base + path, method="HEAD"), timeout=10)
            except urllib.error.HTTPError as e: r = e
            h = {k.lower(): v for k, v in r.headers.items()}; body = r.read(); r.close(); return r.status if hasattr(r, "status") else r.code, h, body
        for path in ("/", "/login", "/healthz", "/static/app.css", "/nowhere"):
            st, h, body = head(path); gst, gh, gbody = self.get(path)
            self.assertEqual((st, body), (gst, b""), path); self.assertEqual(h["content-length"], str(len(gbody)), path)
            self.assertEqual(h.get("content-security-policy"), gh.get("content-security-policy"), path)
        for path in ("/billing/checkout", "/billing/portal", "/v1/reminders/wait"): self.assertEqual(head(path)[0], 405, path)

    def test_static_is_a_closed_set(self):
        for bad in ("/static/../store.py", "/static/%2e%2e/store.py", "/static/..%2fstore.py", "/static/fonts/../../server.py", "/static/", "/static/nope.css", "/static/fonts", "/static//etc/passwd", "/static/app.py"):
            self.assertEqual(self.get(bad)[0], 404, bad)
        _, h, _ = self.get("/static/app.css"); self.assertIn("immutable", h["cache-control"]); self.assertEqual(h["content-type"], "text/css; charset=utf-8")
        _, h, _ = self.get("/static/img/mark.png"); self.assertNotIn("immutable", h["cache-control"])

    def test_privacy_redirects_and_unknown_pages_are_designed_404s(self):
        class NR(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k): return None
        try: urllib.request.build_opener(NR).open(self.base + "/privacy"); self.fail("expected a redirect")
        except urllib.error.HTTPError as e: self.assertEqual((e.code, e.headers["Location"]), (302, ui.PRIVACY)); e.close()
        st, h, body = self.get("/nowhere"); self.assertEqual(st, 404); self.assertIn("nothing here", body.decode())

if __name__ == "__main__": unittest.main()
