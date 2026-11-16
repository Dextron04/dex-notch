"""Stripe, stdlib only: Checkout and the customer portal (outbound), and signed webhooks (inbound).
Access is decided ONLY by webhook events, never by the browser coming back from Checkout."""
import base64, hashlib, hmac, json, sqlite3, time
from typing import Callable, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from .store import USER_ID, Store

TOLERANCE = 300  # seconds a webhook signature stays valid (replay window)
STATUS = {"active": "active", "trialing": "active", "past_due": "past_due",
          "canceled": "canceled", "unpaid": "canceled", "incomplete_expired": "canceled", "paused": "canceled"}  # 'incomplete' = not paid yet: no change

class BillingError(Exception):
    pass

def verify_signature(payload: bytes, header: str, secret: bytes, now: float, tolerance: int = TOLERANCE) -> bool:
    """Stripe-Signature: `t=<unix>,v1=<hex hmac-sha256 of "t.payload">[,v1=...]`. Any matching v1 passes (secret rotation)."""
    try:
        parts = [kv.split("=", 1) for kv in (header or "").split(",")]
        t = int(next(v for k, v in parts if k == "t")); sigs = [v for k, v in parts if k == "v1"]
    except (StopIteration, ValueError): return False
    if abs(now - t) > tolerance or not secret: return False
    want = hmac.new(secret, b"%d." % t + payload, hashlib.sha256).hexdigest()
    return any(hmac.compare_digest(want, s) for s in sigs)

class Stripe:
    def __init__(self, secret_key: str, price_id: str, public_url: str, post: Optional[Callable[[str, dict], dict]] = None):
        self.key, self.price, self.public = secret_key, price_id, public_url.rstrip("/")
        self._post = post or self._http

    def _http(self, path: str, form: dict) -> dict:
        req = Request("https://api.stripe.com/v1" + path, data=urlencode(form).encode(), method="POST", headers={
            "Authorization": "Basic " + base64.b64encode((self.key + ":").encode()).decode(), "Content-Type": "application/x-www-form-urlencoded"})
        try:
            with urlopen(req, timeout=15) as r: return json.load(r)
        except (HTTPError, URLError, ValueError) as e: raise BillingError("stripe request failed: %s" % type(e).__name__)  # never echo the body: it can hold card hints

    def checkout_url(self, uid: str, email: str, customer: Optional[str] = None) -> str:
        form = {"mode": "subscription", "line_items[0][price]": self.price, "line_items[0][quantity]": "1", "client_reference_id": uid,
                "subscription_data[metadata][user_id]": uid, "success_url": self.public + "/billing/success", "cancel_url": self.public + "/billing/cancel"}
        form["customer" if customer else "customer_email"] = customer or email
        url = self._post("/checkout/sessions", form).get("url")
        if not url: raise BillingError("stripe returned no checkout url")
        return url

    def portal_url(self, customer: str) -> str:
        url = self._post("/billing_portal/sessions", {"customer": customer, "return_url": self.public + "/billing/success"}).get("url")
        if not url: raise BillingError("stripe returned no portal url")
        return url

def customer_of(store: Store, uid: str) -> Optional[str]:
    with store.conn() as c: r = c.execute("SELECT stripe_customer_id FROM billing WHERE user_id=?", (uid,)).fetchone()
    return r["stripe_customer_id"] if r else None

def apply_event(store: Store, ev: dict) -> str:
    """Applies one verified Stripe event. Returns what happened: applied | duplicate | stale | ignored.
    One transaction: the event id is recorded together with its effect, so a crash means Stripe retries and nothing is half-applied."""
    obj, typ, ts = (ev.get("data") or {}).get("object") or {}, ev.get("type", ""), float(ev.get("created") or 0)
    if typ not in ("checkout.session.completed", "customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted", "invoice.payment_failed"):
        return "ignored"
    with store.conn() as c:
        try: c.execute("INSERT INTO stripe_events VALUES(?,?)", (ev["id"], time.time()))
        except sqlite3.IntegrityError: return "duplicate"
        customer, sub = obj.get("customer"), obj.get("subscription") if typ in ("checkout.session.completed", "invoice.payment_failed") else obj.get("id")
        cand = obj.get("client_reference_id") if typ == "checkout.session.completed" else (obj.get("metadata") or {}).get("user_id")
        uid = cand if USER_ID.fullmatch(cand or "") and c.execute("SELECT 1 FROM users WHERE id=?", (cand,)).fetchone() else None
        for col, val in (("stripe_customer_id", customer), ("stripe_sub_id", sub)):  # fall back to the ids we stored at checkout
            if not uid and val:
                r = c.execute("SELECT user_id FROM billing WHERE %s=?" % col, (val,)).fetchone(); uid = r["user_id"] if r else None
        if not uid: return "ignored"
        cur = c.execute("SELECT status FROM users WHERE id=?", (uid,)).fetchone()["status"]
        b = c.execute("SELECT event_ts FROM billing WHERE user_id=?", (uid,)).fetchone()
        if cur == "deleted": return "ignored"                                     # a closed account is never revived by a late event
        if b and b["event_ts"] and ts < b["event_ts"]: return "stale"             # events can arrive out of order: newest state wins
        if typ == "checkout.session.completed": new = "active" if obj.get("payment_status") in ("paid", "no_payment_required") else None
        elif typ == "customer.subscription.deleted": new = "canceled"
        elif typ == "invoice.payment_failed": new = "past_due" if cur == "active" else None
        else: new = STATUS.get(obj.get("status"))
        items = ((obj.get("items") or {}).get("data") or [{}])[0]
        end = obj.get("current_period_end") or items.get("current_period_end")
        plan = (items.get("price") or {}).get("id")
        c.execute("INSERT INTO billing(user_id,stripe_customer_id,stripe_sub_id,plan,period_end,event_ts) VALUES(?,?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET "
                  "stripe_customer_id=COALESCE(excluded.stripe_customer_id,stripe_customer_id), stripe_sub_id=COALESCE(excluded.stripe_sub_id,stripe_sub_id), "
                  "plan=COALESCE(excluded.plan,plan), period_end=COALESCE(excluded.period_end,period_end), event_ts=excluded.event_ts",
                  (uid, customer, sub, plan, end, ts))
        if new: c.execute("UPDATE users SET status=? WHERE id=?", (new, uid))
        return "applied"
