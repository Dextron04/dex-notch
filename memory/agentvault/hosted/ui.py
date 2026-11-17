"""Shared page chrome for the hosted service: one layout, a few components, no inline styles or scripts (the CSP forbids them)."""
import hashlib, html
from pathlib import Path
from typing import Optional

STATIC = Path(__file__).resolve().parent / "static"
REPO = "https://github.com/Dextron04/dex-notch"
RELEASES = REPO + "/releases/latest"
PRIVACY, TERMS, STORY = "/privacy", "/terms", "/about"   # read on this site: the documents live in content/
DESCRIPTION = "Dex Notch turns your Mac's notch into a quiet place for mail, iPhone alerts and reminders. Dex Memory keeps every AI conversation you've had where Claude and ChatGPT can search it."

def esc(s) -> str:
    return html.escape("" if s is None else str(s), quote=True)

def _version() -> str:
    h = hashlib.sha256()
    for n in ("app.css", "app.js", "fx.js"): h.update((STATIC / n).read_bytes())
    return h.hexdigest()[:10]
VERSION = _version()  # the stylesheet and script are cached for a year; their URL changes when they do

MARK = '<img class="mark" src="/static/img/mark.png" width="32" height="32" alt="">'  # the app icon: three paths resolving into one amber aperture

CHECK = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>'
CROSS = '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg>'
MAIL = ('<svg viewBox="0 0 48 48" aria-hidden="true" focusable="false"><rect x="6" y="11" width="36" height="26" rx="5" fill="none" stroke="currentColor" stroke-width="2.4"/>'
        '<path d="M8 15l16 12 16-12" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>')

def hidden(fields: dict) -> str:
    return "".join('<input type="hidden" name="%s" value="%s">' % (esc(k), esc(v)) for k, v in fields.items())

FX = f'<script type="module" src="/static/fx.js?v={VERSION}"></script>'   # the long read only: three.js and GSAP, bundled and served from here

def layout(title: str, body: str, *, user: Optional[str] = None, current: str = "", description: str = DESCRIPTION, full_title: bool = False, fx: bool = False) -> str:
    """`user` is the signed-in email (or None). `title` is unique per page: the part before the name is what a tab or a screen reader leads with."""
    if user:
        nav = ('<a href="/account"%s>Account</a><form method="post" action="/logout"><button class="btn btn-quiet btn-sm" type="submit">Sign out</button></form>'
               % (' aria-current="page"' if current == "account" else ""))
    else:
        nav = ('<a class="nav-hide" href="/#how">How it works</a><a class="nav-hide" href="%s"%s>The long read</a><a class="nav-hide" href="%s"%s>Privacy</a>'
               '<a class="btn btn-ghost btn-sm" href="/login"%s>Sign in</a>' % (STORY, ' aria-current="page"' if current == "about" else "", PRIVACY, ' aria-current="page"' if current == "privacy" else "",
                                                                             ' aria-current="page"' if current == "login" else ""))
    page_title = title if full_title else "%s · Dex Notch" % title
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(page_title)}</title>
<meta name="description" content="{esc(description)}">
<meta name="color-scheme" content="dark light">
<meta name="theme-color" content="#09080b" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#f4efe4" media="(prefers-color-scheme: light)">
<meta property="og:title" content="{esc(page_title)}">
<meta property="og:description" content="{esc(description)}">
<link rel="icon" href="/static/img/favicon-32.png" type="image/png" sizes="32x32">
<link rel="icon" href="/static/img/favicon-64.png" type="image/png" sizes="64x64">
<link rel="apple-touch-icon" href="/static/img/apple-touch-icon.png">
<link rel="preload" href="/static/fonts/instrument-serif-latin-400-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/static/fonts/geist-latin-wght-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/static/app.css?v={VERSION}">
<link rel="expect" href="#main" blocking="render">
<script src="/static/app.js?v={VERSION}" defer></script>
{FX if fx else ""}</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site-header">
<div class="wrap">
<a class="brand" href="/" aria-label="Dex Notch, home">{MARK}<span aria-hidden="true">dex<b class="hy">-</b>notch</span></a>
<nav class="nav" aria-label="Primary">{nav}</nav>
</div>
</header>
<main id="main" tabindex="-1">
{body}
</main>
<footer class="site-footer">
<div class="wrap">
<p>Dex Notch is open source and made for the Mac.<br>Early access: expect rough edges.</p>
<nav aria-label="Footer"><ul>
<li><a href="{STORY}">The long read</a></li>
<li><a href="{PRIVACY}">Privacy</a></li>
<li><a href="{TERMS}">Terms</a></li>
<li><a href="{REPO}">Source</a></li>
<li><a href="{RELEASES}">Download</a></li>
</ul></nav>
</div>
</footer>
<div id="live" class="sr-only" role="status" aria-live="polite"></div>
</body>
</html>
"""
