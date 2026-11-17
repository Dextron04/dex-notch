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

def build_sender(a, invite: bool = False, welcome: bool = False):
    """The SMTP sender from the command line, or None when no --smtp-host was given. Fails with a plain message, not a traceback."""
    if not a.smtp_host: return None
    if not a.mail_from: raise SystemExit("--smtp-host needs --mail-from")
    pw = ""
    if a.smtp_password_file:
        try: pw = Path(a.smtp_password_file).expanduser().read_text().strip()
        except OSError as e: raise SystemExit("can't read the SMTP password file %s: %s" % (a.smtp_password_file, e.strerror))
        if not pw: raise SystemExit("the SMTP password file %s is empty" % a.smtp_password_file)
    return smtp_sender(a.smtp_host, a.smtp_port, a.mail_from, a.smtp_user, pw, invite=invite, welcome=welcome)

def main() -> None:
    ap = argparse.ArgumentParser(prog="agentvault.hosted"); sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve"); s.add_argument("--root", required=True); s.add_argument("--public-url", required=True); s.add_argument("--port", type=int, default=8766)
    smtp_args(s)
    s.add_argument("--invite-only", action="store_true", help="closed beta: only existing accounts and invited emails can sign in")
    s.add_argument("--max-users", type=int, default=0, help="stop creating accounts once this many exist (0 = no cap)")
    s.add_argument("--admin", action="append", default=[], metavar="EMAIL", help="may open /admin to manage the waitlist and send invitations (repeatable)")
    iv = sub.add_parser("invite", help="closed beta: let these emails create an account"); iv.add_argument("--root", required=True); iv.add_argument("emails", nargs="+")
    ui = sub.add_parser("uninvite", help="withdraw an invite (an account already created stays)"); ui.add_argument("--root", required=True); ui.add_argument("emails", nargs="+")
    li = sub.add_parser("invites", help="list invited emails and whether each has signed up"); li.add_argument("--root", required=True)
    mt = sub.add_parser("mail-test", help="send one test email through the SMTP settings, to check them without signing in"); mt.add_argument("--public-url", required=True); mt.add_argument("to"); smtp_args(mt)
    s.add_argument("--stripe-key-file"); s.add_argument("--stripe-price"); s.add_argument("--stripe-webhook-secret-file")
    st = sub.add_parser("stats", help="users by status, devices, database size, and the biggest vaults"); st.add_argument("--root", required=True)
    pg = sub.add_parser("purge", help="erase accounts canceled more than N days ago (a dry run unless --yes)"); pg.add_argument("--root", required=True)
    pg.add_argument("--days", type=int, default=30); pg.add_argument("--yes", action="store_true")
    g = sub.add_parser("grant", help="dev override: mark an account paid without Stripe"); g.add_argument("--root", required=True); g.add_argument("email"); g.add_argument("--plan", default="placeholder", help="use \"owner\" for an account with no storage limit")
    a = ap.parse_args()
    if a.cmd == "mail-test":
        send = build_sender(a)
        if not send: raise SystemExit("give --smtp-host (and --mail-from) to test")
        try: send(a.to, a.public_url.rstrip("/") + "/login")
        except Exception as e: raise SystemExit("send failed: %s: %s" % (type(e).__name__, e))
        print("sent to %s: check the inbox (and spam)" % a.to); return
    store = Store(Path(a.root).expanduser())
    if a.cmd == "invite":
        for e in a.emails: print("invited", store.invite(e))
        return
    if a.cmd == "uninvite":
        for e in a.emails: store.uninvite(e); print("withdrawn", e)
        return
    if a.cmd == "invites":
        for e in store.invites(): print(("joined   " if store.by_email(e) else "waiting  ") + e)
        print("%d account(s)" % store.user_count()); return
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
        store.grant(uid, a.plan); print("granted", uid, a.plan); return
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
    srv = make_server(store, Auth(store, invite_only=a.invite_only, max_users=a.max_users), a.public_url, send_mail, stripe, wh, port=a.port,
                      send_invite=build_sender(a, invite=True), admins=a.admin, send_welcome=build_sender(a, welcome=True))
    print("agentvault hosted on 127.0.0.1:%d as %s" % (a.port, a.public_url), flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
