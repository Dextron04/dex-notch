"""Sign-in emails over SMTP (stdlib). Any provider with SMTP works: Resend, Postmark, SES, Mailgun, Gmail."""
import smtplib, ssl
from email.message import EmailMessage
from typing import Callable, Optional

BODY = """Here is your sign-in link:

{link}

It works once and expires in 15 minutes. If you didn't ask for it, ignore this email: nothing happens unless the link is opened.
"""

def smtp_sender(host: str, port: int, sender: str, user: str = "", password: str = "", smtp_factory: Optional[Callable] = None) -> Callable[[str, str], None]:
    """Returns send(email, link). Port 465 = TLS from the start, anything else = STARTTLS (required: we never send a link or a password in clear).
    `smtp_factory` is for tests."""
    def send(email: str, link: str) -> None:
        m = EmailMessage()  # raises ValueError on a newline in any header, so an address can't smuggle in extra headers
        m["From"], m["To"], m["Subject"] = sender, email, "Your sign-in link"
        m.set_content(BODY.format(link=link))
        ctx = ssl.create_default_context()
        if smtp_factory: s = smtp_factory(host, port)
        elif port == 465: s = smtplib.SMTP_SSL(host, port, timeout=10, context=ctx)
        else: s = smtplib.SMTP(host, port, timeout=10)
        with s:
            if port != 465: s.starttls(context=ctx)
            if user: s.login(user, password)
            s.send_message(m)
    return send
