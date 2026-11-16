"""python3 -m agentvault.hosted serve --root DIR --public-url URL [--port N]   |   ... grant --root DIR EMAIL  (placeholder billing)"""
import argparse, sys
from pathlib import Path
from .oauth import Auth
from .server import make_server
from .store import Store

def main() -> None:
    ap = argparse.ArgumentParser(prog="agentvault.hosted"); sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve"); s.add_argument("--root", required=True); s.add_argument("--public-url", required=True); s.add_argument("--port", type=int, default=8766)
    g = sub.add_parser("grant", help="PLACEHOLDER for Stripe: mark an account paid"); g.add_argument("--root", required=True); g.add_argument("email")
    a = ap.parse_args()
    store = Store(Path(a.root).expanduser())
    if a.cmd == "grant":
        uid = store.by_email(a.email)
        if not uid: raise SystemExit("no such account (sign in once first)")
        store.grant(uid); print("granted", uid); return
    def send_mail(email, link):  # PLACEHOLDER: no real email yet, the link goes to the log
        print("SIGN-IN LINK for %s: %s" % (email, link), file=sys.stderr, flush=True)
    srv = make_server(store, Auth(store), a.public_url, send_mail, port=a.port)
    print("agentvault hosted on 127.0.0.1:%d as %s" % (a.port, a.public_url), flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
