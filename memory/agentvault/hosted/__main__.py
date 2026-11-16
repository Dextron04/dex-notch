"""python3 -m agentvault.hosted serve --root DIR --public-url URL [--port N]   |   ... grant --root DIR EMAIL  (placeholder billing)"""
import argparse, sys
from pathlib import Path
from .billing import Stripe
from .oauth import Auth
from .server import make_server
from .store import Store

def main() -> None:
    ap = argparse.ArgumentParser(prog="agentvault.hosted"); sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve"); s.add_argument("--root", required=True); s.add_argument("--public-url", required=True); s.add_argument("--port", type=int, default=8766)
    s.add_argument("--stripe-key-file"); s.add_argument("--stripe-price"); s.add_argument("--stripe-webhook-secret-file")
    g = sub.add_parser("grant", help="dev override: mark an account paid without Stripe"); g.add_argument("--root", required=True); g.add_argument("email")
    a = ap.parse_args()
    store = Store(Path(a.root).expanduser())
    if a.cmd == "grant":
        uid = store.by_email(a.email)
        if not uid: raise SystemExit("no such account (sign in once first)")
        store.grant(uid); print("granted", uid); return
    def send_mail(email, link):  # PLACEHOLDER: no real email yet, the link goes to the log
        print("SIGN-IN LINK for %s: %s" % (email, link), file=sys.stderr, flush=True)
    stripe, wh = None, b""
    if a.stripe_key_file:
        if not (a.stripe_price and a.stripe_webhook_secret_file): raise SystemExit("--stripe-key-file needs --stripe-price and --stripe-webhook-secret-file")
        wh = Path(a.stripe_webhook_secret_file).expanduser().read_text().strip().encode()
        if len(wh) < 20: raise SystemExit("stripe webhook secret looks too short")
        stripe = Stripe(Path(a.stripe_key_file).expanduser().read_text().strip(), a.stripe_price, a.public_url)
    srv = make_server(store, Auth(store), a.public_url, send_mail, stripe, wh, port=a.port)
    print("agentvault hosted on 127.0.0.1:%d as %s" % (a.port, a.public_url), flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
