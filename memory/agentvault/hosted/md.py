"""A tiny markdown renderer for the two legal documents (headings, paragraphs, lists, bold, italic, code, links). Everything is escaped first; links may only be https or on this site."""
import re
from .ui import esc

# the documents link to each other on GitHub; on this site those links stay here
LOCAL = {"https://github.com/Dextron04/dex-notch/blob/master/PRIVACY.md": "/privacy", "https://github.com/Dextron04/dex-notch/blob/master/docs/terms.md": "/terms"}

def _link(label, href):
    href = LOCAL.get(href, href)
    return '<a href="%s">%s</a>' % (href, label) if href.startswith(("https://", "/")) else label

def inline(s: str) -> str:
    out = []
    for i, part in enumerate(re.split(r"(`[^`]+`)", s)):
        if i % 2: out.append("<code>%s</code>" % esc(part[1:-1])); continue
        p = esc(part)
        p = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", lambda m: _link(m[1], m[2]), p)
        p = re.sub(r"&lt;(https://[^\s&]+?)&gt;", lambda m: _link(m[1], m[1]), p)
        p = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", p)
        p = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", p)
        out.append(p)
    return "".join(out)

def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")

def render(text: str):
    """-> (title, [(id, heading)], html)"""
    title, heads, out, para, items, kind = "", [], [], [], [], ""
    def flush():
        nonlocal para, items, kind
        if para: out.append("<p>%s</p>" % inline(" ".join(para))); para = []
        if items: out.append("<%s>%s</%s>" % (kind, "".join("<li>%s</li>" % inline(i) for i in items), kind)); items = []
    for line in text.splitlines():
        m = re.match(r"(\d+\.|-) (.*)", line)
        if line.startswith("# "): flush(); title = line[2:].strip()
        elif line.startswith("## "):
            flush(); h = line[3:].strip(); heads.append((slug(h), h)); out.append('<h2 id="%s">%s</h2>' % (slug(h), inline(h)))
        elif m:
            k = "ul" if m[1] == "-" else "ol"
            if items and k != kind: flush()
            if para: flush()
            kind = k; items.append(m[2])
        elif not line.strip(): flush()
        else: para.append(line.strip())
    flush()
    return title, heads, "\n".join(out)
