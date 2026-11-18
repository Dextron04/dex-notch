"""Every page the hosted service shows to a person. Plain functions that return HTML; the server decides which one, this decides how it reads.
Copy rule: say what happens, in the order it happens, without drama."""
import json, time
from urllib.parse import quote
from typing import List, Optional
from .ui import CHECK, CROSS, INSTALL, MAIL, PRIVACY, RELEASES, STORY, TERMS, REPO, esc, hidden, layout

def _ago(ts: Optional[float], now: float) -> str:
    if not ts: return "never"
    s = max(0, int(now - ts))
    for n, unit in ((86400, "day"), (3600, "hour"), (60, "minute")):
        if s >= n: return "%d %s%s ago" % (s // n, unit, "" if s // n == 1 else "s")
    return "just now"

def _centered(title: str, heading: str, text: str, actions: str = "", *, eyebrow: str = "", code: str = "", user: Optional[str] = None, extra: str = "") -> str:
    body = ('<div class="wrap-narrow centerpage">%s%s<h1>%s</h1><p>%s</p>%s%s</div>'
            % ('<span class="eyebrow">%s</span>' % esc(eyebrow) if eyebrow else "", '<span class="code" aria-hidden="true">%s</span>' % esc(code) if code else "",
               heading, text, '<div class="hero-actions">%s</div>' % actions if actions else "", extra))
    return layout(title, body, user=user)

# ---------------------------------------------------------------- home

def home(user: Optional[str] = None, beta: bool = False) -> str:
    primary = ('<a class="btn" href="/account">Open your account</a>' if user else '<a class="btn" href="/waitlist">Join the beta waitlist</a>' if beta
               else '<a class="btn" href="/login">Create your account</a>')
    body = f"""
<section class="hero" aria-labelledby="hero-title">
<div class="wrap">
<div class="hero-copy">
<span class="eyebrow">Early access · for Mac</span>
<h1 id="hero-title">The things that need you, <em>at the notch.</em></h1>
<p class="lede">Dex Notch turns your Mac's notch into a quiet place for <strong>mail, iPhone alerts and reminders</strong>. Dex Memory keeps every AI conversation you've had in one private place, so Claude and ChatGPT can search it.</p>
<div class="hero-actions">{primary}</div>
<p class="hero-meta">macOS 14 or later · open source · free while in early access · <a href="{STORY}">Read why we're building it</a></p>
</div>

<div class="screen" role="group" aria-label="A demonstration of the notch showing four kinds of card">
<div class="menubar" aria-hidden="true"><span><b>Dex Notch</b><span class="mb-menu">File&nbsp;&nbsp;Edit&nbsp;&nbsp;View&nbsp;&nbsp;Window</span></span><span><time data-clock>9:41 AM</time></span></div>
<div class="dock" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i></div>
<div class="notch" data-notch data-scene="mail">
<article class="scene" data-scene-id="mail" aria-label="Important email">
<div class="scene-top"><span class="tag">gmail · important</span><span>Priya Nair</span></div>
<h3>Interview moved to Thursday 3:00 PM</h3>
<p>A real person is waiting on your reply, and the slot is in two days.</p>
<div class="scene-actions"><span>Open <kbd class="key">⌥↩</kbd></span><span>Reply <kbd class="key">⌥R</kbd></span><span>Not important <kbd class="key">⌥⌫</kbd></span></div>
</article>
<article class="scene" data-scene-id="phone" aria-label="iPhone notification" hidden>
<div class="scene-top"><span class="tag">iphone · messages</span><span>Mom</span></div>
<h3>Call me when you land</h3>
<p>Your iPhone sent it to this Mac. Nothing leaves your Mac to show it here.</p>
<div class="scene-actions"><span>Open <kbd class="key">⌥↩</kbd></span><span>Dismiss <kbd class="key">⌥esc</kbd></span></div>
</article>
<article class="scene" data-scene-id="reminder" aria-label="Reminder" hidden>
<div class="scene-top"><span class="tag">reminder · from Claude</span><span>9:00 AM</span></div>
<h3>Call mum</h3>
<p>You asked for it in a chat. It arrived a second after you said it.</p>
<div class="scene-actions"><span>Done <kbd class="key">⌥↩</kbd></span><span>In 10 min <kbd class="key">⌥esc</kbd></span></div>
</article>
<article class="scene" data-scene-id="memory" aria-label="Memory: recent conversations" hidden>
<div class="scene-top"><span class="tag">memory · running</span><span>esc close</span></div>
<p class="scene-count"><b>141</b> conversations across 5 agents</p>
<ul class="scene-rows plain" role="list">
<li><span class="src">chatgpt</span><span class="ttl">Type scale for long-form posts</span><span class="age">2d</span></li>
<li><span class="src">claude-code</span><span class="ttl">Sandboxed shell for the claude runner</span><span class="age">6h</span></li>
<li><span class="src">codex</span><span class="ttl">Eval harness for tool calling</span><span class="age">6h</span></li>
</ul>
</article>
</div>
</div>
<div class="demo-controls" data-needs-js hidden role="group" aria-label="Demo controls">
<button type="button" data-scene-chip aria-pressed="true">Mail</button>
<button type="button" data-scene-chip aria-pressed="false">iPhone</button>
<button type="button" data-scene-chip aria-pressed="false">Reminder</button>
<button type="button" data-scene-chip aria-pressed="false">Memory</button>
<span class="sep" aria-hidden="true"></span>
<button type="button" data-scene-toggle aria-label="Pause the notch demo">Pause</button>
</div>
</div>
</section>

<section class="section" id="how" aria-labelledby="how-title">
<div class="wrap">
<div class="section-head reveal"><span class="eyebrow">How it works</span><h2 id="how-title">Three steps, then it just runs.</h2></div>
<ol class="how">
<li><h3>Install the app</h3><p>Dex Notch lives in your menu bar and the notch. It reads the AI conversations your Mac already has, from Claude Code, Codex and Gemini, and keeps them in a folder you own.</p></li>
<li><h3>Add your Mac</h3><p>Sign in with an email link, no password. Dex Notch opens your browser, you approve the code it shows, and your history starts uploading.</p></li>
<li><h3>Ask from anywhere</h3><p>In Claude or ChatGPT, add one connector with your memory's address from your account page and sign in once. They can then search and read it, and save new notes and reminders when you ask.</p></li>
</ol>
</div>
</section>

<section class="section" aria-labelledby="what-title">
<div class="wrap">
<div class="section-head reveal"><span class="eyebrow">What you get</span><h2 id="what-title">One memory. Every assistant.</h2></div>
<div class="bento">
<div class="card b-wide">
<h3>Every conversation, one place</h3>
<p>Claude Code, Codex, Gemini, ChatGPT and Claude: all of it in a single searchable list. Ask any of them what you decided last week and they can look it up.</p>
<figure class="shot"><img src="/static/img/shot-chats.png" width="1160" height="800" loading="lazy" alt="The Dex Notch panel listing recent conversations from ChatGPT, Claude Code, Codex and Gemini, with a count of 141 conversations across 5 agents."></figure>
</div>
<div class="card b-narrow">
<h3>Reminders that arrive in a second</h3>
<p>Tell Claude or ChatGPT to remind you. It appears at your notch on time, even if the Mac was asleep.</p>
<div class="bubble me"><small>YOU</small>Remind me to call mum at 9.</div>
<div class="bubble"><small>CLAUDE</small>Set. It will show at your notch at 9:00.</div>
</div>
<div class="card b-narrow">
<h3>Secrets are stripped first</h3>
<p>Keys and passwords are removed on your Mac, and again on the server, before anything is stored.</p>
<p class="mono dim">key is <mark class="redact">[redacted:anthropic]</mark></p>
</div>
<div class="card b-band">
<h3>Yours to take or delete</h3>
<p>Download everything as a zip with one click. Delete your account and your notes go with it, after your subscription is cancelled.</p>
</div>
</div>
</div>
</section>

<section class="section" aria-labelledby="trust-title">
<div class="wrap">
<div class="section-head reveal"><span class="eyebrow">Plainly</span><h2 id="trust-title">What this is, and what it isn't.</h2></div>
<dl class="ledger">
<div class="reveal"><dt>What we keep</dt><dd>Your email address, the names of your Macs, a plan status, and the conversations you choose to upload. No analytics, no ads, no trackers.</dd></div>
<div class="reveal"><dt>Who can read it</dt><dd>Your notes are encrypted on disk with a key only your passphrase opens, so a stolen backup is unreadable. Search has to read them, though, so the service opens them while you use it, and whoever controls the running service could technically watch that happen. Other users never can.</dd></div>
<div class="reveal"><dt>Secrets</dt><dd>Keys and passwords are pattern-matched out before storage. That can't catch everything, so don't rely on it for anything you couldn't afford to leak.</dd></div>
<div class="reveal"><dt>Leaving</dt><dd>Download your data or delete your account at any time. Backups clear within 14 days. <a href="{PRIVACY}">Read the full privacy notes.</a></dd></div>
</dl>
</div>
</section>

<section class="section" aria-labelledby="cta-title">
<div class="wrap">
<div class="cta-band reveal">
<span class="eyebrow">Early access</span>
<h2 id="cta-title">Try it while it's free.</h2>
<p class="lede">No card and no charge while it's in testing. Sign in with an email link and you're set up in about two minutes.</p>
<div class="hero-actions">{primary}<a class="btn btn-ghost" href="{REPO}">Read the source</a></div>
</div>
</div>
</section>
"""
    return layout("The things that need you, at the notch", body, user=user, full_title=False, current="home")

# ---------------------------------------------------------------- sign in

def login(*, beta: bool = False, client_name: Optional[str] = None, fields: Optional[dict] = None, email: str = "", error: str = "", user: Optional[str] = None, link_name: Optional[str] = None) -> str:
    heading = ("Let %s use your memory" % esc(client_name) if client_name else "Add <em>%s</em> to Dex Notch" % esc(link_name) if link_name else "Sign in. <em>No password.</em>")
    lede = ("Sign in to connect it. New here? This creates your account." if client_name or link_name
            else "Use a passkey (Touch ID), or enter your email and we'll send a one-time link. New here? The link creates your account.")
    err = '<p class="form-error" role="alert">%s</p>' % esc(error) if error else ""
    body = f"""
<div class="wrap auth">
<div class="auth-aside">
<span class="eyebrow">Sign in</span>
<h1>{heading}</h1>
<p class="lede">{lede}</p>
</div>
<div class="card auth-card">
<div class="pk-slot">{_passkey("login", "Sign in with a passkey", fields=fields)}<p class="or" data-passkey-or hidden aria-hidden="true">or</p></div>
<h2>Email me a link</h2>
<p class="sub">It works once and expires in 15 minutes.</p>
{err}
<form method="post" action="/login" data-once>
{hidden(fields or {})}
<div class="field">
<label for="email">Email address</label>
<input type="email" id="email" name="email" value="{esc(email)}" required autocomplete="username webauthn" inputmode="email" enterkeyhint="send" spellcheck="false" autocapitalize="none" placeholder="you@example.com" autofocus>
</div>
<button class="btn" type="submit">Email me a sign-in link</button>
</form>
{'<p class="fine">No invite yet? <a href="/waitlist">Join the waitlist</a>.</p>' if beta else ''}
<p class="fine">Dex Notch is a closed beta. By continuing you accept the <a href="{TERMS}">terms</a> and <a href="{PRIVACY}">privacy notes</a>. We email you only this link.</p>
</div>
</div>
"""
    return layout("Sign in", body, user=user, current="login")

def login_sent(email: str, user: Optional[str] = None) -> str:
    body = f"""
<div class="wrap-narrow sent">
<div class="pulse">{MAIL}</div>
<span class="eyebrow">Link sent</span>
<h1>Check your email</h1>
<p class="lede">If <b class="mono">{esc(email)}</b> is a valid address, a sign-in link is on its way. It works once, for 15 minutes.</p>
<p class="dim">Nothing yet? Look in spam, give it a minute, then <a href="/login">try again</a>. Open the link on this device.</p>
</div>
"""
    return layout("Check your email", body, user=user)

def verify(token: str, user: Optional[str] = None) -> str:
    body = f"""
<div class="wrap-narrow centerpage">
<span class="eyebrow">Almost there</span>
<h1>Finish signing in</h1>
<p>One click and you're in. We ask for it so that email scanners opening the link can't use it up.</p>
<form method="post" action="/login/verify" data-once>{hidden({"t": token})}<button class="btn" type="submit">Continue</button></form>
</div>
"""
    return layout("Finish signing in", body, user=user)

# ---------------------------------------------------------------- OAuth consent


def _passkey(kind: str, label: str, *, creds=(), fields=None, nxt: str = "", submit: str = "") -> str:
    """A passkey button. It stays hidden until the page's script finds this browser can do passkeys; without script nothing here shows."""
    data = {"data-passkey": kind}
    if creds: data["data-creds"] = json.dumps(list(creds))
    if fields: data["data-fields"] = json.dumps({k: v for k, v in fields.items() if v})
    if nxt: data["data-next"] = nxt
    if submit: data["data-submit"] = submit
    attrs = " ".join('%s="%s"' % (k, esc(v)) for k, v in data.items())
    return '<button class="btn btn-ghost" type="button" hidden %s>%s</button><p class="form-error" role="alert" data-passkey-msg hidden></p>' % (attrs, esc(label))

def _pass_field(error: str = "", creds=(), submit: str = "") -> str:
    err = '<p class="form-error" role="alert">%s</p>' % esc(error) if error else ""
    pk = (_passkey("unlock", "Use my passkey", creds=creds, submit=submit) + '<input type="hidden" name="credential"><input type="hidden" name="prf">') if creds else ""
    return (pk + err + '<div class="field"><label for="passphrase">Your vault passphrase</label>'
            '<input type="password" id="passphrase" name="passphrase" required autocomplete="current-password" spellcheck="false" autocapitalize="none">'
            '<p class="hint">It unlocks your notes. Dex Notch never sees it after this page.</p></div>')

def vault_setup(email: str, nxt: str, error: str = "", available_for: str = "") -> str:
    err = '<p class="form-error" role="alert">%s</p>' % esc(error) if error else ""
    body = f"""
<div class="wrap auth">
<div class="auth-aside">
<span class="eyebrow">Before anything is saved</span>
<h1>Lock your <em>vault.</em></h1>
<p class="lede">Your notes are encrypted with a key that only you can open, with a passphrase or a touch of your finger. The server keeps the notes and a wrapped copy of the key, never your passphrase, so a copy of the disk or a backup is unreadable.</p>
<p class="dim">While a Mac or an assistant you approved is using your memory, the service opens your notes for that request, as it has to in order to search them. The <a href="{PRIVACY}">privacy notes</a> say exactly what that means.</p>
</div>
<div class="card auth-card">
<h2>Choose a passphrase</h2>
<p class="sub">Signed in as <b class="mono">{esc(email)}</b>. Next you'll get a recovery code. Keep both: without them, nobody can recover your notes.</p>
{err}
{_passkey("setup", "Use Touch ID or a passkey instead", nxt=nxt)}
<form method="post" action="/account/vault" data-once>
{hidden({"next": nxt})}
<div class="field"><label for="p1">Passphrase</label>
<input type="password" id="p1" name="passphrase" required minlength="10" autocomplete="new-password" spellcheck="false" autocapitalize="none" autofocus>
<p class="hint">At least 10 characters. Three or four unrelated words work well.</p></div>
<div class="field"><label for="p2">Again</label>
<input type="password" id="p2" name="confirm" required minlength="10" autocomplete="new-password" spellcheck="false" autocapitalize="none"></div>
<button class="btn" type="submit">Lock my vault</button>
</form>
</div>
</div>
"""
    return layout("Lock your vault", body, user=email)

def vault_recovery(email: str, code: str, nxt: str) -> str:
    body = f"""
<div class="wrap-narrow auth-single">
<div class="card token-card">
<div><span class="eyebrow">Your vault is locked</span><h1>Save your recovery code</h1></div>
<div class="notice"><span>Shown once. If you forget your passphrase, this code is the only other way back in. We can't reset it for you, because we can't read your notes.</span></div>
<div class="copybox"><code id="recovery-code">{esc(code)}</code><button class="btn btn-ghost btn-sm" type="button" data-copy-from="recovery-code">Copy</button></div>
<p class="dim">Put it in your password manager, or print it. Don't keep it next to your passphrase in a note on this Mac.</p>
<div class="row-actions"><a class="btn" href="{esc(nxt)}">I've saved it, continue</a></div>
</div>
</div>
"""
    return layout("Recovery code", body, user=email)

def consent(client_name: str, host: str, email: str, fields: dict, ask: bool = False, error: str = "", creds=()) -> str:
    body = f"""
<div class="wrap-narrow auth-single">
<div class="card auth-card consent">
<span class="eyebrow">Connect</span>
<h1>Let {esc(client_name)} use your memory?</h1>
<p class="sub">You're signed in as <b class="mono">{esc(email)}</b>.</p>
<ul class="perms plain" role="list">
<li><span class="ico">{CHECK}</span><span>Search and read the conversations you've saved</span></li>
<li><span class="ico">{CHECK}</span><span>Save notes and set reminders when you ask it to</span></li>
<li data-no><span class="ico">{CROSS}</span><span>Cannot delete or change anything already saved</span></li>
<li data-no><span class="ico">{CROSS}</span><span>Cannot see any other account</span></li>
</ul>
<form method="post" action="/authorize">
{hidden(fields)}
{_pass_field(error, creds, 'button[value=allow]') if ask else ""}
<div class="consent-actions">
<button class="btn btn-ghost" type="submit" name="decision" value="deny">Deny</button>
<button class="btn" type="submit" name="decision" value="allow">Allow</button>
</div>
</form>
<p class="fine">After you choose, you'll return to <b class="mono">{esc(host)}</b>. Remove access any time from your account page.</p>
</div>
</div>
"""
    return layout("Connect " + client_name, body, user=email)

def link_confirm(email: str, name: str, code: str, ask: bool = False, error: str = "", creds=()) -> str:
    body = f"""
<div class="wrap-narrow auth-single">
<div class="card auth-card consent">
<span class="eyebrow">Add a Mac</span>
<h1>Add <em>{esc(name)}</em> to your account?</h1>
<p class="sub">You're signed in as <b class="mono">{esc(email)}</b>. Check that this code is the one on your Mac's screen:</p>
<p class="pair-code">{esc(code[:4] + "-" + code[4:])}</p>
<ul class="perms plain" role="list">
<li><span class="ico">{CHECK}</span><span>This Mac can save your AI conversations to your memory</span></li>
<li><span class="ico">{CHECK}</span><span>You can remove it from your account page whenever you like</span></li>
<li data-no><span class="ico">{CROSS}</span><span>Don't approve it if the code differs, or you didn't just start this in Dex Notch</span></li>
</ul>
<form method="post" action="/link">
{hidden({"code": code})}
{_pass_field(error, creds, 'button[value=allow]') if ask else ""}
<div class="consent-actions">
<button class="btn btn-ghost" type="submit" name="decision" value="deny">Cancel</button>
<button class="btn" type="submit" name="decision" value="allow">Add this Mac</button>
</div>
</form>
</div>
</div>
"""
    return layout("Add a Mac", body, user=email)

def link_done(name: str, email: str) -> str:
    return _centered("Mac added", "You're <em>in</em>", "<b>%s</b> is linked. Go back to Dex Notch: it finishes setting up on its own. You can close this tab." % esc(name), '<a class="btn btn-ghost" href="/account">Open your account</a>', eyebrow="Done", user=email)

def need_plan(user: str, checkout_link: Optional[str]) -> str:
    action = '<a class="btn" href="%s">Subscribe to continue</a>' % esc(checkout_link) if checkout_link else '<a class="btn btn-ghost" href="/account">Go to your account</a>'
    text = ("Choose a plan to switch your memory on." if checkout_link else
            "Early access is by invitation while it's in testing. Your account is ready; it will start working the moment it's switched on.")
    return _centered("A plan is needed", "Paid plans aren't open yet" if not checkout_link else "A subscription is needed first", text, action, eyebrow="Almost", user=user)

# ---------------------------------------------------------------- account

def account(*, email: str, status: str, entitled: bool, stripe: bool, devices: List[dict], mcp_url: str, connected: bool, used_bytes: int, quota_bytes: int, notes: int,
            now: Optional[float] = None, usable: Optional[bool] = None, encrypted: bool = False, can_encrypt: bool = False, flash: str = "",
            passkeys: Optional[List[dict]] = None, unlocked: bool = False, has_passphrase: bool = True, rp_id: str = "", passkey_user: str = "", progress: Optional[set] = None) -> str:
    now = now or time.time()
    usable = entitled if usable is None else usable
    tone, label = {"active": ("ok", "Active"), "past_due": ("warn", "Payment issue"), "canceled": ("warn", "Canceled"), "pending": ("ok", "Free plan")}.get(status, ("warn", status.title()))
    if entitled and status == "active": intro = "You're in. Everything on this page is live."
    elif entitled: intro = "Your card needs attention, but everything still works while it's retried."
    elif usable: intro = "You're on the free plan: %s of memory, everything on this page is live." % ("no storage limit" if quota_bytes is None else "%d MB" % (quota_bytes // 1048576))
    elif status == "canceled": intro = "Your plan ended. Your notes are kept so you can still download them."
    elif stripe: intro = "Choose a plan to switch on uploads and your connector."
    else: intro = "Your account is ready, but paid plans aren't open yet. Early access is by invitation: once you're switched on, this page updates and the steps below start working."
    bill = ""
    if stripe: bill = '<a class="btn btn-ghost btn-sm" href="/billing/%s">%s</a>' % (("portal", "Manage subscription") if entitled else ("checkout", "Subscribe"))
    rows = "".join(
        '<li><div><div class="name">%s</div><div class="meta">added %s · last seen %s</div></div>'
        '<form method="post" action="/account/devices/revoke">%s<button class="btn btn-quiet btn-sm" type="submit">Remove<span class="sr-only"> %s</span></button></form></li>'
        % (esc(d["name"]), time.strftime("%b %-d", time.gmtime(d["created_at"])), _ago(d["last_seen"], now), hidden({"id": d["id"]}), esc(d["name"])) for d in devices)
    passkeys = passkeys or []
    creds = [p["id"] for p in passkeys if p["unlocks"]]
    pk_rows = "".join(
        '<li><div><div class="name">%s</div><div class="meta">added %s · last used %s · %s</div></div>'
        '<form method="post" action="/account/passkeys/remove">%s<button class="btn btn-quiet btn-sm" type="submit">Remove<span class="sr-only"> %s</span></button></form></li>'
        % (esc(p["name"]), time.strftime("%b %-d", time.gmtime(p["created"])), _ago(p["last_used"], now), "opens your notes" if p["unlocks"] else "signs in only", hidden({"id": p["id"]}), esc(p["name"])) for p in passkeys)
    pk_card = ('<section class="card" aria-labelledby="pk-title" data-passkey-sync data-rp="%s" data-user="%s" data-ids="%s">' % (esc(rp_id), esc(passkey_user), esc(json.dumps([p["id"] for p in passkeys]))) + '<div class="card-head"><h2 id="pk-title">Passkeys</h2><p>Touch ID, your phone or a security key</p></div>'
               + (('<ul class="devices plain" role="list">' + pk_rows + '</ul>') if pk_rows else '<p class="empty">No passkeys yet. Add one and a touch signs you in.</p>')
               + ('<p class="hint">Your vault has no passphrase yet. The recovery code is your way back in if every passkey is lost.</p>' if encrypted and not has_passphrase else '')
               + ('<div class="field"><label for="pk-pass">Vault passphrase <span class="dim">(needed once, to let this passkey open your notes)</span></label><input type="password" id="pk-pass" name="passphrase" autocomplete="current-password" spellcheck="false"></div>' if encrypted and not unlocked and has_passphrase else '')
               + _passkey("add", "Add a passkey") + '</section>') if (encrypted or not can_encrypt) else ""
    pct = 0 if quota_bytes is None else min(100, used_bytes * 100 // max(quota_bytes, 1))
    used = "%.1f MB" % (used_bytes / 1048576) if used_bytes >= 104858 else "under 0.1 MB"
    progress = progress or set()
    steps = [bool(devices)] + ([encrypted] if can_encrypt else []) + ["uploaded" in progress, connected, "assistant_used" in progress]
    done_n = sum(1 for x in steps if x)
    body = f"""
<div class="wrap">
<header class="page-head">
<span class="eyebrow">Account</span>
<h1>Your memory</h1>
<div class="who"><span class="mono">{esc(email)}</span><span class="chip" data-tone="{tone}"><i></i>{esc(label)}</span>{bill}</div>
<p class="dim">{intro}</p>
</header>
{('<div class="notice" role="status"><span><b>Lock your vault to keep your Mac and assistants working.</b> Until you do, they are paused and your saved notes are not encrypted. <a href="#vault-title">Lock it now</a>.</span></div>') if can_encrypt and not encrypted else ""}
<div class="stack">
<section class="card" aria-labelledby="setup-title">
<div class="card-head"><h2 id="setup-title">Get set up</h2><p>{done_n} of {len(steps)} done</p></div>
<ol class="checklist">
<li {"data-done" if devices else ""}><span class="dot" aria-hidden="true"></span><h3>Install Dex Notch and sign in</h3>
<div class="body"><p>Version 0.9 or later, on macOS 14 or newer. Open it, press <b>Continue in browser</b>, and check that the code on the page matches the one on your Mac. <a href="{INSTALL}">Install guide</a></p><div class="row-actions"><a class="btn btn-ghost btn-sm" href="{RELEASES}">Download for Mac</a></div></div></li>
{('<li %s><span class="dot" aria-hidden="true"></span><h3>Lock your vault</h3><div class="body"><p>Choose Touch ID or a passphrase, and keep the recovery code. Your notes are encrypted with a key only you can open.%s</p></div></li>' % ("data-done" if encrypted else "", "" if encrypted else ' <a href="#vault-title">Lock it now</a>')) if can_encrypt else ""}
<li {"data-done" if "uploaded" in progress else ""}><span class="dot" aria-hidden="true"></span><h3>Record your conversations</h3>
<div class="body"><p>Dex Notch starts a small helper after you sign in that saves your Claude Code, Codex and Gemini conversations and uploads them. This step is done when the first ones arrive. If it isn't, open <b>Settings → Memory</b> in Dex Notch and press <b>Start recording</b>.</p></div></li>
<li {"data-done" if connected else ""}><span class="dot" aria-hidden="true"></span><h3>Connect Claude or ChatGPT{' <span class="chip" data-tone="ok"><i></i>Connected</span>' if connected else ''}</h3>
<div class="body"><p><a class="btn btn-sm" href="{esc(add_to_claude(mcp_url))}" target="_blank" rel="noopener">Add to Claude</a> opens Claude with Dex Memory ready to add: confirm it, sign in as <span class="mono">{esc(email)}</span>, and press <b>Allow</b>. For ChatGPT, or to do it by hand, paste this address:</p>
<div class="copybox"><code id="mcp-url">{esc(mcp_url)}</code><button class="btn btn-ghost btn-sm" type="button" data-copy-from="mcp-url">Copy</button></div>
<p><a href="/connect">Step-by-step for Claude, ChatGPT, Claude Code and Codex</a></p>
<details><summary>Already have an older Dex connector?</summary><p>Remove it in the same Connectors list first, then add this one. The old one points at a previous vault that no longer updates.</p></details></div></li>
<li {"data-done" if "assistant_used" in progress else ""}><span class="dot" aria-hidden="true"></span><h3>Have your first conversation{' <span class="chip" data-tone="ok"><i></i>Done</span>' if "assistant_used" in progress else ''}</h3>
<div class="body"><p>In Claude or ChatGPT, paste this:</p>
<div class="copybox"><code id="try-1">Remember this for me: I'm trying out Dex Memory, and my favorite color is amber.</code><button class="btn btn-ghost btn-sm" type="button" data-copy-from="try-1">Copy</button></div>
<p>Then open a <b>new</b> chat, in the same assistant or the other one, and paste:</p>
<div class="copybox"><code id="try-2">Search my Dex memory: what did I say my favorite color was?</code><button class="btn btn-ghost btn-sm" type="button" data-copy-from="try-2">Copy</button></div>
<p class="hint">If it answers "amber", everything works: each assistant can use what the others saved. Conversations you have in Claude Code, Codex or Gemini are saved on their own, so you can also ask <i>"what did I work on in Claude Code today?"</i></p></div></li>
</ol>
</section>

<section class="card" aria-labelledby="macs-title">
<div class="card-head"><h2 id="macs-title">Your Macs</h2><p>Each one uploads with its own key.</p></div>
{('<ul class="devices plain" role="list">' + rows + '</ul>') if rows else '<p class="empty">No Macs yet. Add one in step 2 above.</p>'}
</section>

<section class="card" aria-labelledby="storage-title">
<div class="card-head"><h2 id="storage-title">Storage</h2><p>{notes:,} saved conversation{'' if notes == 1 else 's'}</p></div>
<progress class="meter" value="{pct}" max="100" aria-label="Storage used">{pct}%</progress>
<p class="hint">{used} used{", no limit." if quota_bytes is None else " of %d MB." % (quota_bytes // 1048576)}</p>
</section>


{('<section class="card" aria-labelledby="vault-title"><div class="card-head"><h2 id="vault-title">Vault encryption</h2><p><span class="chip" data-tone="ok"><i></i>On</span></p></div>'
  '<p class="dim">Your notes are encrypted at rest. Change the passphrase here; you need your current passphrase or your recovery code.</p>'
  + ('<p class="form-error" role="alert">%s</p>' % esc(flash) if flash else '') +
  '<form method="post" action="/account/vault/passphrase" data-once><div class="form-row">'
  '<div class="field"><label for="cur">Current passphrase</label><input type="password" id="cur" name="passphrase" autocomplete="current-password" spellcheck="false"></div>'
  '<div class="field"><label for="rec">or recovery code</label><input type="text" id="rec" name="recovery" autocomplete="off" spellcheck="false" autocapitalize="characters"></div></div>'
  '<div class="field"><label for="new">New passphrase</label><input type="password" id="new" name="new" required minlength="10" autocomplete="new-password" spellcheck="false"></div>'
  '<button class="btn btn-ghost btn-sm" type="submit">Change passphrase</button></form></section>') if encrypted else
 ('<section class="card" aria-labelledby="vault-title"><div class="card-head"><h2 id="vault-title">Vault encryption</h2><p><span class="chip" data-tone="warn"><i></i>Off</span></p></div>'
  '<p class="dim">Encrypt your notes with a key that only your passphrase opens. Your Macs and assistants will need to sign in again afterwards.</p>'
  + ('<p class="form-error" role="alert">%s</p>' % esc(flash) if flash else '') +
  '<form method="post" action="/account/vault" data-once>' + _passkey("setup", "Use Touch ID or a passkey instead", nxt="/account") + hidden({"next": "/account"}) +
  '<div class="field"><label for="p1">Passphrase</label><input type="password" id="p1" name="passphrase" required minlength="10" autocomplete="new-password" spellcheck="false"></div>'
  '<div class="field"><label for="p2">Again</label><input type="password" id="p2" name="confirm" required minlength="10" autocomplete="new-password" spellcheck="false"></div>'
  '<button class="btn btn-sm" type="submit">Lock my vault</button></form></section>' if can_encrypt else '')}
{pk_card}

<section class="card" aria-labelledby="data-title">
<div class="card-head"><h2 id="data-title">Your data</h2></div>
<div class="row-actions">
<form method="post" action="/account/export">{(_passkey("unlock", "Use my passkey", creds=creds, submit="button[type=submit]") + '<input type="hidden" name="credential"><input type="hidden" name="prf">' if creds else '') + '<input type="password" name="passphrase" required autocomplete="current-password" placeholder="Vault passphrase" aria-label="Vault passphrase" spellcheck="false"> ' if encrypted else ''}<button class="btn btn-ghost btn-sm" type="submit">Download my data</button></form>
<form method="post" action="/account/signout-all"><button class="btn btn-ghost btn-sm" type="submit">Sign out everywhere</button></form>
</div>
<p class="hint">The download is a zip of every note and a small account file.</p>
</section>

<section class="card danger-zone" aria-labelledby="danger-title">
<div class="card-head"><h2 id="danger-title">Delete account</h2></div>
<p class="dim">Cancels your subscription, then permanently erases your notes, Macs and sign-ins. It can't be undone.</p>
<div class="row-actions"><button class="btn btn-danger btn-sm" type="button" command="show-modal" commandfor="delete-dialog">Delete my account…</button></div>
</section>
</div>
</div>

<dialog id="delete-dialog" aria-labelledby="delete-title" closedby="any">
<form method="post" action="/account/delete" data-once>
<h2 id="delete-title">Delete your account?</h2>
<p class="dim">This erases every saved conversation and removes your Macs. Download your data first if you want a copy.</p>
<div class="field"><label for="confirm">Type <b class="mono">{esc(email)}</b> to confirm</label>
<input type="text" id="confirm" name="confirm" required autocomplete="off" spellcheck="false" autocapitalize="none" data-must-equal="{esc(email)}"></div>
<div class="actions">
<button class="btn btn-ghost" type="button" command="close" commandfor="delete-dialog" autofocus>Keep my account</button>
<button class="btn btn-danger" type="submit">Delete forever</button>
</div>
</form>
</dialog>
"""
    return layout("Account", body, user=email, current="account")

def device_token(token: str, name: str, mcp_url: str, email: str) -> str:
    host = mcp_url.split("//")[1].split("/")[0]
    body = f"""
<div class="wrap-narrow auth-single">
<div class="card token-card">
<div><span class="eyebrow">New Mac</span><h1>Paste this into Dex Notch</h1></div>
<div class="notice"><span>Shown once. Anyone holding this token can upload notes to your account. If it leaks, remove the Mac from your account page.</span></div>
<div class="copybox"><code id="device-token">{esc(token)}</code><button class="btn btn-ghost btn-sm" type="button" data-copy-from="device-token">Copy</button></div>
<ol>
<li>Open <b>Dex Notch → Settings → Memory</b>.</li>
<li>Enter the server: <span class="mono">{esc(host)}</span></li>
<li>Paste the token for <b>{esc(name or 'this Mac')}</b> and press <b>Connect</b>.</li>
</ol>
<div class="row-actions"><a class="btn" href="/account">Back to your account</a></div>
</div>
</div>
"""
    return layout("Your device token", body, user=email, current="account")

# ---------------------------------------------------------------- status and errors

def billing_done(ok: bool, user: Optional[str]) -> str:
    if ok: return _centered("Thank you", "You're all set", "Your plan switches on in a few seconds. Go back to Claude or ChatGPT and connect again, or head to your account.", '<a class="btn" href="/account">Open your account</a>', eyebrow="Payment received", user=user)
    return _centered("No charge made", "Nothing was charged", "You left before paying, so your plan is unchanged. You can come back any time.", '<a class="btn btn-ghost" href="/account">Back to your account</a>', eyebrow="Cancelled", user=user)

def goodbye() -> str:
    return _centered("Account deleted", "Your account is gone", "Your notes, Macs and sign-ins were erased. Backups made before today are overwritten within 14 days. Thanks for trying it.", '<a class="btn btn-ghost" href="/">Back to the start</a>', eyebrow="Deleted")

_ERRORS = {
    400: ("That request didn't look right", "Go back and try again."),
    401: ("You need to sign in", "Your session may have ended."),
    402: ("Your plan isn't active", "Your account isn't switched on for this yet."),
    404: ("There's nothing here", "The page you wanted doesn't exist, or it moved."),
    429: ("Slow down a little", "Too many tries in a short while. Wait a minute, then try again."),
    502: ("Payments are unavailable", "We couldn't reach the payment provider. Nothing was changed. Try again shortly."),
}

def error(code: int, message: str = "", user: Optional[str] = None) -> str:
    heading, hint = _ERRORS.get(code, ("Something went wrong", "Try again in a moment."))
    action = '<a class="btn" href="/login">Sign in</a>' if code == 401 else '<a class="btn btn-ghost" href="%s">%s</a>' % (("/account", "Your account") if user else ("/", "Back to the start"))
    return _centered(heading, heading, esc(message) if message else hint, action, code=str(code), user=user)



# ---------------------------------------------------------------- connecting assistants

AGENT_SNIPPET = """<!-- dex-memory:begin -->
## Dex memory
At the end of a conversation, save it to the user's Dex memory so their other assistants can find it.
- When the work is finished, or the user says thanks, goodbye or that they are done, call the `remember` tool once. It belongs to the Dex memory connector (`dex-memory`).
- `title`: a few words. `content`: a short summary in markdown, not a transcript: what was decided, what was built or changed, facts worth keeping, and open questions. `source`: `claude` if you are Claude, `chatgpt` if you are ChatGPT, otherwise `other`.
- Never include passwords, API keys, tokens or personal data.
- Skip it if the user asked you not to save, if the conversation was trivial, or if you have no `remember` tool. Do not mention the tool unless it fails. When it works, say "Saved to your memory." in one line.
<!-- dex-memory:end -->"""   # the same words the Mac app writes into the agents' instruction files (tests keep the two equal)

def _cmd(cid: str, text: str) -> str:
    return '<div class="copybox"><code id="%s">%s</code><button class="btn btn-ghost btn-sm" type="button" data-copy-from="%s">Copy</button></div>' % (cid, esc(text), cid)

def _state(on: Optional[bool]) -> str:
    return "" if on is None else ('<span class="chip" data-tone="ok"><i></i>Connected</span>' if on else '<span class="chip" data-tone="warn"><i></i>Not connected yet</span>')

def add_to_claude(mcp_url: str) -> str:
    """claude.ai's add-a-custom-connector dialog with the name and address filled in (documented by Anthropic); the person confirms there."""
    return "https://claude.ai/customize/connectors?modal=add-custom-connector&connectorName=Dex%20Memory&connectorUrl=" + quote(mcp_url, safe="")

def connect(mcp_url: str, user: Optional[str] = None, assistants: Optional[dict] = None, encrypted: bool = False) -> str:
    a = assistants or {}
    who = ("Signed in as <b class=\"mono\">%s</b>. " % esc(user)) if user else '<a href="/login">Sign in</a> to see which are connected. '
    unlock = " You'll be asked for your vault passphrase, or a touch, on the way." if encrypted else ""
    body = f"""
<div class="wrap">
<header class="page-head">
<span class="eyebrow">Cross-context memory</span>
<h1>Connect your <em>assistants</em></h1>
<p class="dim">New here? The <a href="{INSTALL}">install guide</a> goes from invitation to your first conversation. One memory, every assistant. Connect each one once, and Claude, ChatGPT and your coding agents can all search what the others learned: decide something in a terminal, ask about it from your phone. They all use the same address.</p>
</header>
<div class="stack">
<section class="card" aria-labelledby="url-title">
<div class="card-head"><h2 id="url-title">Your address</h2><p>{who}</p></div>
{_cmd("mcp-url", mcp_url)}
<p class="hint">Each assistant opens this site, you sign in, and you press <b>Allow</b>.{unlock} They can search and read your saved conversations, and save notes and reminders when you ask. They cannot delete or change anything, and cannot see any other account. Remove any of them later from your account page.</p>
</section>

<section class="card" id="claude" aria-labelledby="claude-title">
<div class="card-head"><h2 id="claude-title">Claude</h2><p>claude.ai, the desktop app, your phone and Claude Code {_state(a.get("claude") if user else None)}</p></div>
<p><a class="btn btn-sm" href="{esc(add_to_claude(mcp_url))}" target="_blank" rel="noopener">Add to Claude</a></p>
<ol class="checklist">
<li><span class="dot" aria-hidden="true"></span><h3>Add the connector</h3><div class="body"><p>The button above opens Claude with Dex Memory ready to add. Or do it by hand: <b>Settings → Connectors → Add custom connector</b>, name it Dex Memory, and paste the address above.</p></div></li>
<li><span class="dot" aria-hidden="true"></span><h3>Sign in and allow</h3><div class="body"><p>Claude opens this site. Sign in and press <b>Allow</b>.</p></div></li>
<li><span class="dot" aria-hidden="true"></span><h3>Try it</h3><div class="body"><p>Ask Claude <i>"what did I decide about the schema last week?"</i> It searches your memory. <b>Claude Code</b> on your Mac shares the connectors on your Claude account, so it picks this one up too.</p></div></li>
</ol>
<details id="claude-code"><summary>Claude Code didn't pick it up?</summary><p>Add it from the terminal, then start <code>claude</code>, type <code>/mcp</code>, choose <b>dex-memory</b> and sign in:</p>
{_cmd("cmd-claude", "claude mcp add --transport http --scope user dex-memory " + mcp_url)}</details>
</section>

<section class="card" id="chatgpt" aria-labelledby="chatgpt-title">
<div class="card-head"><h2 id="chatgpt-title">ChatGPT</h2><p>chatgpt.com, the apps and Codex {_state(a.get("chatgpt") if user else None)}</p></div>
<ol class="checklist">
<li><span class="dot" aria-hidden="true"></span><h3>Add the connector</h3><div class="body"><p>Open <b>Settings → Connectors</b> and create a connector. ChatGPT may ask you to turn on developer mode first. Name it Dex Memory, paste the address above, and choose <b>OAuth</b> for authentication.</p></div></li>
<li><span class="dot" aria-hidden="true"></span><h3>Sign in and allow</h3><div class="body"><p>ChatGPT opens this site. Sign in and press <b>Allow</b>.</p></div></li>
<li><span class="dot" aria-hidden="true"></span><h3>Add it to Codex too</h3><div class="body"><p>ChatGPT on the web doesn't hand its connectors to <b>Codex</b>, so Codex needs its own copy. Dex Notch on your Mac does this when you press Connect in Settings → Memory, or run these two commands:</p>
<div id="codex">{_cmd("cmd-codex", "codex mcp add dex-memory --url " + mcp_url)}{_cmd("cmd-codex-login", "codex mcp login dex-memory")}</div></div></li>
</ol>
<p class="hint">Then tell Claude <i>"remember this conversation"</i> and ask ChatGPT about it. Both read and write the same memory.</p>
</section>

<section class="card" id="save" aria-labelledby="save-title">
<div class="card-head"><h2 id="save-title">Save every conversation</h2><p>for all of them</p></div>
<p class="dim">Add this to the place each assistant keeps its standing instructions, and it saves a short summary to your memory when a conversation ends.</p>
<div class="copybox"><pre id="agent-snippet">{esc(AGENT_SNIPPET)}</pre><button class="btn btn-ghost btn-sm" type="button" data-copy-from="agent-snippet">Copy</button></div>
<ul class="plain" role="list">
<li><b>ChatGPT:</b> Settings → Personalization → Custom instructions.</li>
<li><b>Claude:</b> your personal preferences, or a project's instructions.</li>
<li><b>Claude Code, Codex, Gemini:</b> <code>~/.claude/CLAUDE.md</code>, <code>~/.codex/AGENTS.md</code>, <code>~/.gemini/GEMINI.md</code>. Dex Notch on your Mac adds it to all three with one button: Settings → Memory.</li>
</ul>
<p class="hint">An assistant decides for itself when a conversation is over, so this isn't guaranteed. You can always say "save this to my memory".</p>
</section>

<section class="card" aria-labelledby="watch-title">
<div class="card-head"><h2 id="watch-title">Dex Notch keeps watch</h2></div>
<p class="dim">The Mac app looks for Claude and Codex on your Mac and checks that each is connected to your memory. If one isn't, the notch tells you once, with a button to fix it. You can turn the reminders off in Settings → Memory.</p>
</section>
</div>
</div>
"""
    return layout("Connect an assistant", body, user=user, current="connect", description="Add Dex Memory to Claude, ChatGPT, Claude Code or Codex so every assistant can search and add to the same memory.")

# ---------------------------------------------------------------- closed beta: waitlist and the operator's page

def waitlist_form(*, error: str = "", email: str = "", user: Optional[str] = None) -> str:
    err = '<p class="form-error" role="alert">%s</p>' % esc(error) if error else ""
    body = f"""
<div class="wrap auth">
<div class="auth-aside">
<span class="eyebrow">Closed beta</span>
<h1>Ask for <em>an invite.</em></h1>
<p class="lede">Dex Notch is being tested with a small group. Leave your email and, when there is room, you'll get an invitation with the download and the sign-in.</p>
</div>
<div class="card auth-card">
<h2>Join the waitlist</h2>
<p class="sub">We email you once: the invitation. No newsletter.</p>
{err}
<form method="post" action="/waitlist" data-once>
<div class="field">
<label for="email">Email address</label>
<input type="email" id="email" name="email" value="{esc(email)}" required autocomplete="email" inputmode="email" spellcheck="false" autocapitalize="none" placeholder="you@example.com" autofocus>
</div>
<div class="field">
<label for="note">What would you use it for? <span class="dim">(optional)</span></label>
<input type="text" id="note" name="note" maxlength="300" autocomplete="off">
</div>
<div class="field" hidden><input type="text" name="website" tabindex="-1" autocomplete="off"></div>
<button class="btn" type="submit">Join the waitlist</button>
</form>
<p class="fine">It needs a Mac on macOS 14 or later (<a href="{INSTALL}">install guide</a>). See the <a href="{TERMS}">terms</a> and <a href="{PRIVACY}">privacy notes</a>. Already invited? <a href="/login">Sign in</a>.</p>
</div>
</div>
"""
    return layout("Waitlist", body, user=user)

def waitlist_done(user: Optional[str] = None) -> str:
    return _centered("You're on the list", "You're <em>on the list</em>", "If that address is valid, it is on the waitlist. When there is room you'll get one email with the invitation.",
                     '<a class="btn btn-ghost" href="/">Back to the start</a>', eyebrow="Waitlist", user=user)

def admin(*, email: str, waiting: List[dict], invited: List[dict], members: int, cap: int, mail_ok: bool, flash: str = "", now: float = 0, unlocked: Optional[int] = None, vault_mail: bool = False) -> str:
    def row(w, button):
        return ('<li><div><div class="name">%s</div><div class="meta">%s%s</div></div><div class="row-actions">%s'
                '<form method="post" action="/admin/waitlist/remove">%s<button class="btn btn-quiet btn-sm" type="submit">Remove<span class="sr-only"> %s</span></button></form></div></li>'
                % (esc(w["email"]), "joined %s" % _ago(w["created"], now), (" · " + esc(w["note"])) if w["note"] else "", button, hidden({"email": w["email"]}), esc(w["email"])))
    inv_btn = lambda w, label: ('<form method="post" action="/admin/invite">%s<button class="btn btn-ghost btn-sm" type="submit">%s<span class="sr-only"> %s</span></button></form>'
                                % (hidden({"email": w["email"]}), label, esc(w["email"])))
    wr = "".join(row(w, inv_btn(w, "Invite")) for w in waiting)
    ir = "".join(row(w, inv_btn(w, "Resend")) for w in invited)
    note = "" if mail_ok else '<p class="form-error" role="alert">Email is not set up on this server, so invitations are only written to the log.</p>'
    fl = '<p class="hint" role="status">%s</p>' % esc(flash) if flash else ""
    body = f"""
<div class="wrap">
<header class="page-head"><span class="eyebrow">Operator</span><h1>Closed beta</h1>
<div class="who"><span class="mono">{esc(email)}</span><span class="chip" data-tone="ok"><i></i>{members} of {cap or "unlimited"} places used</span></div></header>
<div class="stack">
{note}{fl}
<section class="card" aria-labelledby="w-title">
<div class="card-head"><h2 id="w-title">Waiting ({len(waiting)})</h2>
<form method="post" action="/admin/invite">{hidden({"all": "1"})}<button class="btn btn-sm" type="submit"{"" if waiting else " disabled"}>Invite everyone waiting</button></form></div>
{('<ul class="devices plain" role="list">' + wr + '</ul>') if wr else '<p class="empty">Nobody is waiting.</p>'}
</section>
<section class="card" aria-labelledby="i-title">
<div class="card-head"><h2 id="i-title">Invite an address</h2><p>Doesn't need to be on the waitlist.</p></div>
<form method="post" action="/admin/invite"><div class="form-row"><div class="field"><label for="a-email">Email address</label>
<input type="email" id="a-email" name="email" required spellcheck="false" autocapitalize="none"></div></div><button class="btn" type="submit">Send invitation</button></form>
</section>
{('<section class="card" aria-labelledby="v-title"><div class="card-head"><h2 id="v-title">Vaults not locked yet (%d)</h2></div><p class="dim">Their Macs and assistants are paused until they lock their vault. This emails each of them once, and no one more than once a week.</p><form method="post" action="/admin/vault-reminders"><button class="btn" type="submit"%s>Email them</button></form></section>' % (unlocked, "" if unlocked and vault_mail else " disabled")) if unlocked is not None else ""}
<section class="card" aria-labelledby="s-title">
<div class="card-head"><h2 id="s-title">Invited ({len(invited)})</h2></div>
{('<ul class="devices plain" role="list">' + ir + '</ul>') if ir else '<p class="empty">No invitations sent yet.</p>'}
</section>
</div></div>
"""
    return layout("Closed beta", body, user=email)
