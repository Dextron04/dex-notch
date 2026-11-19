"""Sign-in emails over SMTP (stdlib). Any provider with SMTP works: Resend, Postmark, SES, Mailgun, Gmail."""
import smtplib, ssl
from email.message import EmailMessage
from typing import Callable, Optional

BODY = """Here is your sign-in link:

{link}

It works once and expires in 15 minutes. If you didn't ask for it, ignore this email: nothing happens unless the link is opened.
"""

INVITE_BODY = """You're in. Dex Notch is open to you in its closed beta.

Setting up takes about five minutes:

1. Download the app and drag it to Applications: {download}
   macOS says it can't verify the app (it isn't notarized yet). The install guide shows the two clicks that allow it.
2. Sign up here: {link}
   Use this email address ({email}): the invitation is for it.
3. Lock your vault with a passkey (Touch ID, your phone or a security key), or a passphrase if your device can't do passkeys, and save the recovery code you're shown. This comes first: nothing else works until you do.
4. Open Dex Notch and press Continue in browser to link your Mac, then connect Claude or ChatGPT from your account page.
5. Say hello: ask your AI to remember something, then ask another one to find it. Your account page has the exact words.

Install guide: {guide}

It is early software and it will have rough edges. In Dex Notch, Settings → Memory → "Copy diagnostics" and "Report a problem" are there for exactly that: tell us what broke.

You asked for this on the waitlist. If that wasn't you, ignore this email: nothing happens.
"""

WELCOME_BODY = """Your Dex Notch account is ready ({email}).

Where you are, and what's left:

1. Lock your vault with a passkey (Touch ID, your phone or a security key), or a passphrase if your device can't do passkeys, and keep the recovery code. Sign in to see the page: {account}
   Nothing else works until this is done.
2. Install Dex Notch if you haven't: {download}
3. Open it and press Continue in browser. Check that the code matches and tap Add this Mac.
4. Connect Claude or ChatGPT from your account page.
5. Have your first conversation: your account page has two lines to paste, one to save something and one to find it again.

The account page also lets you download everything or delete your account at any time. Install guide: {guide}

It is a closed beta, so expect rough edges. In Dex Notch, Settings → Memory → "Copy diagnostics" and "Report a problem" are there for when something breaks.
"""

VAULT_BODY = """Dex Notch now encrypts the conversations you've saved, with a key only you can open. Until you lock your vault, your Mac and your Claude or ChatGPT connection are paused, and your saved notes are not encrypted yet. Signing in takes you straight to the page that locks it.

It takes about a minute:

1. Sign in: {account}
2. Create a passkey (Touch ID, your phone or a security key), or choose a passphrase, and save the recovery code it shows you once.
3. Your Mac signs in again by itself the next time Dex Notch opens, and your assistants ask you to approve them once more.

Your notes are kept. If you'd rather not continue, you can download everything or delete your account from the same page.

You get this email once a week at most, and only while your vault is not locked.
"""

def smtp_sender(host: str, port: int, sender: str, user: str = "", password: str = "", smtp_factory: Optional[Callable] = None, invite: bool = False, welcome: bool = False, vault: bool = False,
                download: str = "https://github.com/Dextron04/dex-notch/releases/latest",
                guide: str = "https://github.com/Dextron04/dex-notch/blob/master/docs/install.md") -> Callable[[str, str], None]:
    """Returns send(email, link). Port 465 = TLS from the start, anything else = STARTTLS (required: we never send a link or a password in clear).
    `smtp_factory` is for tests."""
    def send(email: str, link: str) -> None:
        m = EmailMessage()  # raises ValueError on a newline in any header, so an address can't smuggle in extra headers
        m["From"], m["To"], m["Subject"] = sender, email, ("Lock your Dex Notch vault" if vault else "Welcome to Dex Notch" if welcome else "You're invited to the Dex Notch beta" if invite else "Your sign-in link")
        m.set_content(VAULT_BODY.format(account=link) if vault else WELCOME_BODY.format(email=email, download=download, account=link, guide=guide) if welcome else INVITE_BODY.format(link=link, email=email, download=download, guide=guide) if invite
                      else BODY.format(link=link))
        ctx = ssl.create_default_context()
        if smtp_factory: s = smtp_factory(host, port)
        elif port == 465: s = smtplib.SMTP_SSL(host, port, timeout=10, context=ctx)
        else: s = smtplib.SMTP(host, port, timeout=10)
        with s:
            if port != 465: s.starttls(context=ctx)
            if user: s.login(user, password)
            s.send_message(m)
    return send
