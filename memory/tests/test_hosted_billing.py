import hashlib, hmac, json, sys, tempfile, threading, unittest, urllib.error, urllib.parse, urllib.request
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agentvault.hosted import billing
from agentvault.hosted.billing import BillingError, Stripe, apply_event, verify_signature
from agentvault.hosted.oauth import Auth
from agentvault.hosted.server import make_server
from agentvault.hosted.store import Store

SECRET, PUB, NOW = b"whsec_" + b"x" * 30, "https://hosted.example.test", 1_700_000_000

def sign(payload: bytes, t=NOW, secret=SECRET):
    return "t=%d,v1=%s" % (t, hmac.new(secret, b"%d." % t + payload, hashlib.sha256).hexdigest())

def ev(id, typ, obj, created=NOW): return {"id": id, "type": typ, "created": created, "data": {"object": obj}}

class SignatureTests(unittest.TestCase):
    def test_signature(self):
        p = b'{"id":"evt_1"}'
        self.assertTrue(verify_signature(p, sign(p), SECRET, NOW))
        self.assertTrue(verify_signature(p, sign(p) + ",v1=" + "0" * 64, SECRET, NOW))              # rotation: any v1 may match
        self.assertTrue(verify_signature(p, "v1=" + "0" * 64 + "," + sign(p), SECRET, NOW + 299))
        for hdr, now in ((sign(p, secret=b"wrong" * 8), NOW), (sign(p), NOW + 301), (sign(p, NOW - 400), NOW), ("", NOW), ("garbage", NOW), ("t=abc,v1=00", NOW)):
            self.assertFalse(verify_signature(p, hdr, SECRET, now), hdr)
        self.assertFalse(verify_signature(p + b" ", sign(p), SECRET, NOW))                          # body tampered
        self.assertFalse(verify_signature(p, sign(p), b"", NOW))

class EventTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.s = Store(Path(self.d.name)); self.u = self.s.create_user("a@x.io")

    def sub(self, status, id="evt", created=NOW, **kw):
        return ev(id, "customer.subscription.updated", dict({"id": "sub_1", "customer": "cus_1", "status": status, "metadata": {"user_id": self.u},
               "current_period_end": NOW + 99, "items": {"data": [{"price": {"id": "price_1"}}]}}, **kw), created)

    def test_checkout_completed_activates_and_links_ids(self):
        r = apply_event(self.s, ev("e1", "checkout.session.completed", {"client_reference_id": self.u, "customer": "cus_1", "subscription": "sub_1", "payment_status": "paid"}))
        self.assertEqual(r, "applied"); self.assertTrue(self.s.entitled(self.u)); self.assertEqual(billing.customer_of(self.s, self.u), "cus_1")
        with self.s.conn() as c: self.assertEqual(c.execute("SELECT stripe_sub_id FROM billing").fetchone()[0], "sub_1")

    def test_unpaid_checkout_does_not_activate(self):
        apply_event(self.s, ev("e1", "checkout.session.completed", {"client_reference_id": self.u, "customer": "cus_1", "payment_status": "unpaid"}))
        self.assertFalse(self.s.entitled(self.u))

    def test_subscription_lifecycle(self):
        for i, (st, entitled) in enumerate((("active", True), ("past_due", True), ("canceled", False), ("trialing", True), ("unpaid", False), ("active", True), ("incomplete", True))):
            self.assertEqual(apply_event(self.s, self.sub(st, "e%d" % i, NOW + i)), "applied"); self.assertEqual(self.s.entitled(self.u), entitled, st)
        self.assertEqual(self.s.status(self.u), "active")                                            # 'incomplete' changed nothing
        apply_event(self.s, ev("del", "customer.subscription.deleted", {"id": "sub_1", "customer": "cus_1"}, NOW + 50))
        self.assertEqual(self.s.status(self.u), "canceled")                                          # found by stored ids, no metadata needed
        with self.s.conn() as c: self.assertEqual(tuple(c.execute("SELECT plan, period_end FROM billing").fetchone()), ("price_1", NOW + 99))

    def test_payment_failed_only_downgrades_active(self):
        apply_event(self.s, self.sub("active", "a", NOW))
        apply_event(self.s, ev("f", "invoice.payment_failed", {"customer": "cus_1", "subscription": "sub_1"}, NOW + 1)); self.assertEqual(self.s.status(self.u), "past_due")
        apply_event(self.s, self.sub("canceled", "c", NOW + 2))
        apply_event(self.s, ev("f2", "invoice.payment_failed", {"customer": "cus_1", "subscription": "sub_1"}, NOW + 3)); self.assertEqual(self.s.status(self.u), "canceled")

    def test_duplicates_stale_unknown_and_deleted(self):
        e = self.sub("active", "same", NOW + 10)
        self.assertEqual(apply_event(self.s, e), "applied"); self.assertEqual(apply_event(self.s, e), "duplicate")
        self.assertEqual(apply_event(self.s, self.sub("canceled", "old", NOW + 5)), "stale"); self.assertTrue(self.s.entitled(self.u))  # older event arriving late
        self.assertEqual(apply_event(self.s, ev("x", "customer.subscription.updated", {"id": "sub_9", "customer": "cus_9", "status": "active", "metadata": {"user_id": "u_" + "A" * 22}})), "ignored")
        self.assertEqual(apply_event(self.s, ev("y", "charge.succeeded", {})), "ignored")
        self.s.set_status(self.u, "deleted")
        self.assertEqual(apply_event(self.s, self.sub("active", "late", NOW + 99)), "ignored"); self.assertEqual(self.s.status(self.u), "deleted")

    def test_forged_user_id_cannot_grant_someone_else(self):
        other = self.s.create_user("b@x.io")                          # metadata only counts when the event is Stripe-signed; still, an unknown id is ignored
        self.assertEqual(apply_event(self.s, ev("z", "customer.subscription.updated", {"id": "s", "customer": "c", "status": "active", "metadata": {"user_id": "not-an-id"}})), "ignored")
        self.assertFalse(self.s.entitled(other))

class FakeStripe:
    def __init__(self): self.calls = []
    def __call__(self, path, form):
        self.calls.append((path, form)); return {"url": "https://stripe.test/pay/" + path.strip("/").replace("/", "_")}

NoRedirect = type("NR", (urllib.request.HTTPRedirectHandler,), {"redirect_request": lambda self, *a, **k: None})
OPENER = urllib.request.build_opener(NoRedirect)
def call(method, url, body=None, headers=None, form=False, raw=None):
    data = raw if raw is not None else (None if body is None else (urllib.parse.urlencode(body).encode() if form else json.dumps(body).encode()))
    try:
        r = OPENER.open(urllib.request.Request(url, data=data, method=method, headers=headers or {}), timeout=10); return r.status, dict(r.headers), r.read().decode()
    except urllib.error.HTTPError as e:
        b = e.read().decode(); e.close(); return e.code, dict(e.headers), b

class ServerBillingTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.addCleanup(self.d.cleanup)
        self.store, self.mail, self.fake = Store(Path(self.d.name)), [], FakeStripe()
        self.stripe = Stripe("sk_test_x", "price_1", PUB, post=self.fake)
        self.srv = make_server(self.store, Auth(self.store, now=lambda: NOW), PUB, lambda e, l: self.mail.append((e, l)),
                               self.stripe, SECRET, port=0, now=lambda: NOW)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close); self.addCleanup(self.srv.shutdown)
        self.base = "http://127.0.0.1:%d" % self.srv.server_address[1]
        call("POST", self.base + "/login", {"email": "a@x.io"}, form=True)
        st, h, _ = call("POST", self.base + "/login/verify", {"t": self.mail[-1][1].split("t=")[1]}, form=True)
        self.ck = {"Cookie": h["Set-Cookie"].split(";")[0]}; self.uid = self.store.by_email("a@x.io")

    def hook(self, e, sig=None):
        raw = json.dumps(e).encode()
        return call("POST", self.base + "/hooks/stripe", raw=raw, headers={"Stripe-Signature": sign(raw) if sig is None else sig})

    def test_checkout_redirects_to_stripe_and_never_grants_by_itself(self):
        st, h, _ = call("GET", self.base + "/billing/checkout", headers=self.ck)
        self.assertEqual((st, h["Location"]), (302, "https://stripe.test/pay/checkout_sessions"))
        path, form = self.fake.calls[0]
        self.assertEqual((form["client_reference_id"], form["customer_email"], form["line_items[0][price]"], form["mode"]), (self.uid, "a@x.io", "price_1", "subscription"))
        self.assertEqual(form["subscription_data[metadata][user_id]"], self.uid); self.assertFalse(self.store.entitled(self.uid))
        self.assertEqual(call("GET", self.base + "/billing/success")[0], 200); self.assertFalse(self.store.entitled(self.uid))   # returning from Stripe proves nothing
        self.assertEqual(call("GET", self.base + "/billing/checkout")[0], 401)

    def test_webhook_flow_then_portal(self):
        self.assertEqual(call("GET", self.base + "/billing/portal", headers=self.ck)[0], 404)   # no customer yet
        st, _, body = self.hook(ev("e1", "checkout.session.completed", {"client_reference_id": self.uid, "customer": "cus_1", "subscription": "sub_1", "payment_status": "paid"}))
        self.assertEqual((st, json.loads(body)["result"]), (200, "applied")); self.assertTrue(self.store.entitled(self.uid))
        self.assertEqual(self.hook(ev("e1", "checkout.session.completed", {"client_reference_id": self.uid, "customer": "cus_1"}))[2], '{"result": "duplicate"}')
        st, h, _ = call("GET", self.base + "/billing/checkout", headers=self.ck)                  # already subscribed: goes to the portal instead
        self.assertEqual((st, h["Location"]), (302, "https://stripe.test/pay/billing_portal_sessions")); self.assertEqual(self.fake.calls[-1][1]["customer"], "cus_1")

    def test_returning_customer_reuses_stripe_customer(self):
        apply_event(self.store, ev("e1", "checkout.session.completed", {"client_reference_id": self.uid, "customer": "cus_1", "payment_status": "paid"}))
        apply_event(self.store, ev("e2", "customer.subscription.deleted", {"id": "s", "customer": "cus_1"}, NOW + 1))
        call("GET", self.base + "/billing/checkout", headers=self.ck); form = self.fake.calls[-1][1]
        self.assertEqual(form["customer"], "cus_1"); self.assertNotIn("customer_email", form)

    def test_webhook_rejects_bad_signature_and_bad_bodies(self):
        e = ev("e1", "checkout.session.completed", {"client_reference_id": self.uid, "payment_status": "paid"})
        for sig in ("", "t=1,v1=00", sign(b"other body")): self.assertEqual(self.hook(e, sig)[0], 400)
        self.assertFalse(self.store.entitled(self.uid))
        raw = b"not json"; self.assertEqual(call("POST", self.base + "/hooks/stripe", raw=raw, headers={"Stripe-Signature": sign(raw)})[0], 400)

    def test_failed_apply_returns_500_so_stripe_retries(self):
        real, billing.apply_event = billing.apply_event, lambda *a: 1 / 0
        self.addCleanup(setattr, billing, "apply_event", real)
        self.assertEqual(self.hook(ev("e9", "checkout.session.completed", {}))[0], 500)

    def test_stripe_errors_are_reported_not_leaked(self):
        def boom(path, form): raise BillingError("stripe request failed: HTTPError")
        self.stripe._post = boom
        st, _, body = call("GET", self.base + "/billing/checkout", headers=self.ck)
        self.assertEqual(st, 502); self.assertNotIn("sk_test", body)

    def test_billing_off_without_stripe(self):
        s2 = make_server(self.store, Auth(self.store), PUB, lambda e, l: None, port=0)
        threading.Thread(target=s2.serve_forever, daemon=True).start(); self.addCleanup(s2.server_close); self.addCleanup(s2.shutdown)
        b2 = "http://127.0.0.1:%d" % s2.server_address[1]
        self.assertEqual(call("GET", b2 + "/billing/checkout", headers=self.ck)[0], 404)
        self.assertEqual(call("POST", b2 + "/hooks/stripe", raw=b"{}", headers={"Stripe-Signature": sign(b"{}")})[0], 404)

if __name__ == "__main__": unittest.main()
