"""Sign-in emails over SMTP (stdlib). Any provider with SMTP works: Resend, Postmark, SES, Mailgun, Gmail."""
import smtplib, ssl
from email.message import EmailMessage
from typing import Callable, Optional

BODY = """Here is your sign-in link:

{link}

It works once and expires in 15 minutes. If you didn't ask for it, ignore this email: nothing happens unless the link is opened.
"""

INVITE_BODY = """You're in. Dex Notch is open to you in its closed beta.

1. Download the app: {download}
2. Open it and choose Continue in browser, or sign in here: {link}
   Use this email address ({email}): the invitation is for it.

It is early software and it will have rough edges. In Settings → Memory, "Copy diagnostics" and "Report a problem" are there for exactly that: tell us what broke.

You asked for this on the waitlist. If that wasn't you, ignore this email: nothing happens.
"""

WELCOME_BODY = """Your Dex Notch account is ready ({email}).

1. Install Dex Notch: {download}
2. Open it. It opens a page in your browser; check the code matches and tap Add this Mac.
3. Optional: connect Claude or ChatGPT from your account page, so they can search your conversations: {account}

Your account page also lets you download everything or delete your account at any time.

It is a closed beta, so expect rough edges. In Dex Notch, Settings → Memory → "Copy diagnostics" and "Report a problem" are there for when something breaks.
"""

def smtp_sender(host: str, port: int, sender: str, user: str = "", password: str = "", smtp_factory: Optional[Callable] = None, invite: bool = False, welcome: bool = False,
                download: str = "https://github.com/Dextron04/dex-notch/releases/latest") -> Callable[[str, str], None]:
    """Returns send(email, link). Port 465 = TLS from the start, anything else = STARTTLS (required: we never send a link or a password in clear).
    `smtp_factory` is for tests."""
    def send(email: str, link: str) -> None:
        m = EmailMessage()  # raises ValueError on a newline in any header, so an address can't smuggle in extra headers
        m["From"], m["To"], m["Subject"] = sender, email, ("Welcome to Dex Notch" if welcome else "You're invited to the Dex Notch beta" if invite else "Your sign-in link")
        m.set_content(WELCOME_BODY.format(email=email, download=download, account=link) if welcome else INVITE_BODY.format(link=link, email=email, download=download) if invite
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
