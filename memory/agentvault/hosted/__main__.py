"""python3 -m agentvault.hosted serve --root DIR --public-url URL [--port N] [--smtp-host H --mail-from F ...] [--stripe-... ]   |   ... grant --root DIR EMAIL"""
import argparse, json, sys, time
from pathlib import Path
from .billing import Stripe
from .ingest import vault_bytes
from .mail import smtp_sender
from .oauth import Auth
from .server import make_server
from .store import Store

def smtp_args(p) -> None:
    p.add_argument("--smtp-host"); p.add_argument("--smtp-port", type=int, default=587); p.add_argument("--smtp-user", default="")
    p.add_argument("--smtp-password-file"); p.add_argument("--mail-from", help='e.g. "Dex Notch <login@yourdomain>"')

def build_sender(a):
    """The SMTP sender from the command line, or None when no --smtp-host was given. Fails with a plain message, not a traceback."""
    if not a.smtp_host: return None
    if not a.mail_from: raise SystemExit("--smtp-host needs --mail-from")
    pw = ""
    if a.smtp_password_file:
        try: pw = Path(a.smtp_password_file).expanduser().read_text().strip()
        except OSError as e: raise SystemExit("can't read the SMTP password file %s: %s" % (a.smtp_password_file, e.strerror))
        if not pw: raise SystemExit("the SMTP password file %s is empty" % a.smtp_password_file)
    return smtp_sender(a.smtp_host, a.smtp_port, a.mail_from, a.smtp_user, pw)

def main() -> None:
    ap = argparse.ArgumentParser(prog="agentvault.hosted"); sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve"); s.add_argument("--root", required=True); s.add_argument("--public-url", required=True); s.add_argument("--port", type=int, default=8766)
    smtp_args(s)
    mt = sub.add_parser("mail-test", help="send one test email through the SMTP settings, to check them without signing in"); mt.add_argument("--public-url", required=True); mt.add_argument("to"); smtp_args(mt)
    s.add_argument("--stripe-key-file"); s.add_argument("--stripe-price"); s.add_argument("--stripe-webhook-secret-file")
    st = sub.add_parser("stats", help="users by status, devices, database size, and the biggest vaults"); st.add_argument("--root", required=True)
    pg = sub.add_parser("purge", help="erase accounts canceled more than N days ago (a dry run unless --yes)"); pg.add_argument("--root", required=True)
    pg.add_argument("--days", type=int, default=30); pg.add_argument("--yes", action="store_true")
    g = sub.add_parser("grant", help="dev override: mark an account paid without Stripe"); g.add_argument("--root", required=True); g.add_argument("email")
    a = ap.parse_args()
    if a.cmd == "mail-test":
        send = build_sender(a)
        if not send: raise SystemExit("give --smtp-host (and --mail-from) to test")
        try: send(a.to, a.public_url.rstrip("/") + "/login")
        except Exception as e: raise SystemExit("send failed: %s: %s" % (type(e).__name__, e))
        print("sent to %s: check the inbox (and spam)" % a.to); return
    store = Store(Path(a.root).expanduser())
    if a.cmd == "stats":
        print(json.dumps(store.stats(), indent=1))
        sizes = sorted(((vault_bytes(d / "Vault"), d.name) for d in (store.root / "data").glob("u_*") if d.is_dir()), reverse=True)[:10]
        print("largest vaults (MB):", [(round(b / 1e6, 1), u) for b, u in sizes]); return
    if a.cmd == "purge":
        old = store.canceled_before(time.time() - a.days * 86400)
        print("%d account(s) canceled more than %d days ago: %s" % (len(old), a.days, old))
        if a.yes:
            for u in old: store.delete_account(u)
            print("erased")
        elif old: print("dry run: add --yes to erase them")
        return
    if a.cmd == "grant":
        uid = store.by_email(a.email)
        if not uid: raise SystemExit("no such account (sign in once first)")
        store.grant(uid); print("granted", uid); return
    send_mail = build_sender(a)
    if not send_mail:
        def send_mail(email, link):  # dev only: no SMTP configured, so the link goes to the log. Anyone who can read the log can sign in as that user.
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
