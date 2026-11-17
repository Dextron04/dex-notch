"""Every page the hosted service shows to a person. Plain functions that return HTML; the server decides which one, this decides how it reads.
Copy rule: say what happens, in the order it happens, without drama."""
import time
from typing import List, Optional
from .ui import CHECK, CROSS, MAIL, PRIVACY, RELEASES, REPO, esc, hidden, layout

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

def home(user: Optional[str] = None) -> str:
    primary = '<a class="btn" href="/account">Open your account</a>' if user else '<a class="btn" href="/login">Create your account</a>'
    body = f"""
<section class="hero" aria-labelledby="hero-title">
<div class="wrap">
<div class="hero-copy">
<span class="eyebrow">Early access · for Mac</span>
<h1 id="hero-title">The things that need you, <em>at the notch.</em></h1>
<p class="lede">Dex Notch turns your Mac's notch into a quiet place for <strong>mail, iPhone alerts and reminders</strong>. Dex Memory keeps every AI conversation you've had in one private place, so Claude and ChatGPT can search it.</p>
<div class="hero-actions">{primary}<a class="btn btn-ghost" href="{RELEASES}">Download for Mac</a></div>
<p class="hero-meta">macOS 14 or later · open source · free while in early access</p>
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
<li><h3>Ask from anywhere</h3><p>Add your memory as a connector in Claude or ChatGPT. They can search it, read it, and save new notes and reminders when you ask them to.</p></li>
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
<div class="reveal"><dt>Who can read it</dt><dd>The person who runs this server can, technically. Notes are encrypted on the way here but are not end-to-end encrypted, because search has to read them. Other users never can.</dd></div>
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

def login(*, client_name: Optional[str] = None, fields: Optional[dict] = None, email: str = "", error: str = "", user: Optional[str] = None, link_name: Optional[str] = None) -> str:
    heading = ("Let %s use your memory" % esc(client_name) if client_name else "Add <em>%s</em> to Dex Notch" % esc(link_name) if link_name else "One link. <em>No password.</em>")
    lede = ("Sign in to connect it. New here? This creates your account." if client_name or link_name
            else "Enter your email and we'll send a link that signs you in. New here? It creates your account.")
    err = '<p class="form-error" role="alert">%s</p>' % esc(error) if error else ""
    body = f"""
<div class="wrap auth">
<div class="auth-aside">
<span class="eyebrow">Sign in</span>
<h1>{heading}</h1>
<p class="lede">{lede}</p>
</div>
<div class="card auth-card">
<h2>Email me a link</h2>
<p class="sub">It works once and expires in 15 minutes.</p>
{err}
<form method="post" action="/login" data-once>
{hidden(fields or {})}
<div class="field">
<label for="email">Email address</label>
<input type="email" id="email" name="email" value="{esc(email)}" required autocomplete="email" inputmode="email" enterkeyhint="send" spellcheck="false" autocapitalize="none" placeholder="you@example.com" autofocus>
</div>
<button class="btn" type="submit">Email me a sign-in link</button>
</form>
<p class="fine">By continuing you accept the <a href="{PRIVACY}">privacy notes</a>. We email you only this link.</p>
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

def consent(client_name: str, host: str, email: str, fields: dict) -> str:
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

def link_confirm(email: str, name: str, code: str) -> str:
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
            now: Optional[float] = None, usable: Optional[bool] = None) -> str:
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
    pct = 0 if quota_bytes is None else min(100, used_bytes * 100 // max(quota_bytes, 1))
    used = "%.1f MB" % (used_bytes / 1048576) if used_bytes >= 104858 else "under 0.1 MB"
    step2 = "data-done" if devices else ""
    body = f"""
<div class="wrap">
<header class="page-head">
<span class="eyebrow">Account</span>
<h1>Your memory</h1>
<div class="who"><span class="mono">{esc(email)}</span><span class="chip" data-tone="{tone}"><i></i>{esc(label)}</span>{bill}</div>
<p class="dim">{intro}</p>
</header>
<div class="stack">
<section class="card" aria-labelledby="setup-title">
<div class="card-head"><h2 id="setup-title">Get set up</h2><p>About two minutes</p></div>
<ol class="checklist">
<li><span class="dot" aria-hidden="true"></span><h3>Install Dex Notch</h3>
<div class="body"><p>Version 0.8 or later. It needs macOS 14.</p><div class="row-actions"><a class="btn btn-ghost btn-sm" href="{RELEASES}">Download for Mac</a></div></div></li>
<li {step2}><span class="dot" aria-hidden="true"></span><h3>Add this Mac</h3>
<div class="body"><p>Open Dex Notch on the Mac. It opens a page in your browser; sign in, check the code matches and tap <b>Add this Mac</b>. Your history starts uploading within a minute (you can turn that off in Settings → Memory).</p></div></li>
<li {"data-done" if connected else ""}><span class="dot" aria-hidden="true"></span><h3>Connect Claude or ChatGPT{' <span class="chip" data-tone="ok"><i></i>Connected</span>' if connected else ''}</h3>
<div class="body"><p>Add a custom connector and paste this address. You'll be asked to sign in and approve it once.</p>
<div class="copybox"><code id="mcp-url">{esc(mcp_url)}</code><button class="btn btn-ghost btn-sm" type="button" data-copy-from="mcp-url">Copy</button></div>
<details><summary>Where do I paste it?</summary><p><b>Claude:</b> Settings → Connectors → Add custom connector.<br><b>ChatGPT:</b> Settings → Connectors, then create a connector (it may need developer mode).</p></details></div></li>
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

<section class="card" aria-labelledby="data-title">
<div class="card-head"><h2 id="data-title">Your data</h2></div>
<div class="row-actions">
<form method="post" action="/account/export"><button class="btn btn-ghost btn-sm" type="submit">Download my data</button></form>
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
