"""The long read (/about) and the two legal documents, read on this site instead of on GitHub."""
from pathlib import Path
from typing import Optional
from . import md
from .ui import PRIVACY, REPO, STORY, TERMS, esc, layout

CONTENT = Path(__file__).resolve().parent / "content"

def _toc(heads) -> str:
    return '<nav class="toc" aria-label="On this page"><p class="eyebrow">On this page</p><ol>%s</ol></nav>' % "".join('<li><a href="#%s">%s</a></li>' % (i, esc(t)) for i, t in heads)

def legal(name: str, user: Optional[str] = None) -> str:
    """name is 'privacy' or 'terms'."""
    title, heads, body = md.render((CONTENT / (name + ".md")).read_text())
    other = ('<a href="%s">Terms of use</a>' % TERMS) if name == "privacy" else ('<a href="%s">Privacy notes</a>' % PRIVACY)
    page = f"""
<div class="wrap longread{' has-toc' if len(heads) > 2 else ''}">
<header class="read-head"><span class="eyebrow">Legal</span><h1>{esc(title)}</h1></header>
{_toc(heads) if len(heads) > 2 else ''}
<article class="prose">
{body}
<p class="prose-foot">Also read: {other}. Questions? <a href="{REPO}/issues">Open an issue</a>.</p>
</article>
</div>"""
    return layout(title.split(":")[0], page, user=user, current=name, description="What Dex Notch and the hosted memory service store, who can read it, and how to leave.")

# ---------------------------------------------------------------- the long read

SECTIONS = [("problem", "The problem"), ("answer", "What Dex does about it"), ("why", "Why it matters for AI developers"), ("trust", "What you have to trust"),
            ("scale", "How it grows"), ("together", "Many people, one session"), ("roadmap", "The road from here")]

FIGURE = """<figure class="figure">
<svg viewBox="0 0 680 280" role="img" aria-labelledby="fig-t fig-d" focusable="false">
<title id="fig-t">Three people and their agents writing into one shared session</title>
<desc id="fig-d">You with Claude Code, a teammate with Codex, and a second teammate with ChatGPT each send turns into one shared session. Every turn is labelled with who wrote it. The session is saved to a shared vault that only its members can read.</desc>
<g class="f-node"><rect x="8" y="22" width="178" height="56" rx="14"/><rect x="8" y="112" width="178" height="56" rx="14"/><rect x="8" y="202" width="178" height="56" rx="14"/></g>
<g class="f-label"><text x="26" y="46">You</text><text x="26" y="64" class="f-dim">Claude Code</text><text x="26" y="136">Priya</text><text x="26" y="154" class="f-dim">Codex</text><text x="26" y="226">Sam</text><text x="26" y="244" class="f-dim">ChatGPT</text></g>
<g class="f-wire"><path d="M186 50 C 240 50, 246 112, 292 124"/><path d="M186 140 H 292"/><path d="M186 230 C 240 230, 246 168, 292 156"/></g>
<g class="f-hub"><rect x="292" y="52" width="210" height="176" rx="18"/></g>
<g class="f-label"><text x="308" y="82" class="f-eyebrow">ONE SESSION</text>
<text x="308" y="110"><tspan class="f-who">you</tspan> · sketch the schema</text>
<text x="308" y="136"><tspan class="f-who">priya</tspan> · run the eval</text>
<text x="308" y="162"><tspan class="f-who">sam</tspan> · any edge cases?</text>
<text x="308" y="188"><tspan class="f-who">claude</tspan> · two fail, see why</text>
<text x="308" y="214" class="f-dim">every line says who wrote it</text></g>
<g class="f-wire"><path d="M502 140 H 556"/><path d="M548 132 l 8 8 l -8 8"/></g>
<g class="f-node f-vault"><rect x="556" y="92" width="116" height="96" rx="14"/></g>
<g class="f-label"><text x="574" y="130">Shared</text><text x="574" y="150">vault</text><text x="574" y="172" class="f-dim">members only</text></g>
</svg>
<figcaption>The plan: several people, each with their own agent, adding to one session. Not built yet.</figcaption>
</figure>"""

def about(user: Optional[str] = None, beta: bool = False) -> str:
    cta = ('<a class="btn" href="/account">Open your account</a>' if user else '<a class="btn" href="/waitlist">Join the beta waitlist</a>' if beta
           else '<a class="btn" href="/login">Create your account</a>')
    toc = _toc(SECTIONS)
    body = f"""
<canvas class="scene-bg" aria-hidden="true"></canvas>
<div class="read-progress" aria-hidden="true"></div>
<div class="wrap longread has-toc">
<header class="read-head">
<span class="eyebrow">The long read</span>
<h1>Your AI work should <em>add up.</em></h1>
<p class="standfirst">Every serious developer now works with several AI agents. Each one starts the day knowing nothing. Dex is the memory that sits underneath all of them, and the notch is where it taps you on the shoulder.</p>
<p class="byline">About 6 minutes · closed beta · <a href="{PRIVACY}">privacy</a> · <a href="{TERMS}">terms</a></p>
</header>
{toc}
<article class="prose">

<h2 id="problem">The problem</h2>
<p>Pick a week of real work. On Monday you settle a design question with Claude Code. On Wednesday Codex runs your evals and finds a regression. On Friday you ask ChatGPT to help you write it up, and it has never heard of any of it. You paste the context in again. You explain the repository again. You re-argue a decision you already made.</p>
<blockquote class="pull">Today the context you build evaporates when a chat ends, and the person left holding it is you.</blockquote>
<p>This is not a flaw in any one assistant. It is the shape of the market. Each vendor keeps its own history in its own format on its own machine: one folder of session files here, a browser tab there, a cloud account somewhere else. None of them can see the others, and none of them is built to. The only thing that connects your agents is you, copying and pasting.</p>
<p>The Mac has a second, smaller version of the same problem. Everything that needs you arrives in a different place: mail in one app, your iPhone's alerts on another device, reminders you told an assistant about and never saw again. The screen you are already looking at, the notch, has no say in any of it.</p>

<h2 id="answer">What Dex does about it</h2>
<p>Dex has three parts, and each is deliberately plain.</p>
<ol class="parts">
<li><strong>A recorder.</strong> It reads the session files your agents already write (Claude Code, Codex, Gemini) and saves each conversation as a plain markdown note in a folder you own. Passwords and API keys are removed before a note is written.</li>
<li><strong>A vault.</strong> That folder is the memory. It is ordinary markdown with links between notes, so you can open it in any editor, search it with <code>grep</code>, back it up, or walk away with it. The optional hosted version keeps a copy on a server so it is reachable from anywhere.</li>
<li><strong>A connector.</strong> Claude and ChatGPT connect to the vault through MCP, the open standard assistants use to call tools. Once you approve it, they can search your history, read a note, save something new, and set a reminder.</li>
</ol>
<p>The notch is the surface. A reminder you ask for in a chat shows up there a second later. An email that needs a reply, or a notification from your iPhone, lands in the same quiet place instead of three loud ones.</p>

<h2 id="why">Why it matters for AI developers</h2>
<p>A few things are true of building with AI today that were not true two years ago, and the memory problem sits at the centre of each.</p>
<dl class="points">
<div><dt>Agents are plural.</dt><dd>People use one tool for refactors, another for evals, another for long documents, another for thinking out loud. Memory that belongs to one vendor is memory with holes in it.</dd></div>
<div><dt>Decisions live in transcripts.</dt><dd>The code shows what you built. Why you built it that way is in a conversation nobody can find. Searchable history turns "why did we do it like this?" from archaeology into a lookup.</dd></div>
<div><dt>Plain files outlast products.</dt><dd>Notes are markdown. Nothing is locked in a format only Dex can read, and you can download every note as a zip whenever you like.</dd></div>
<div><dt>One socket beats many plugs.</dt><dd>Because the vault speaks MCP, a new assistant needs no new integration. If it can call a tool, it can remember.</dd></div>
<div><dt>Handoffs get cheap.</dt><dd>Start in one agent, continue in another, and the second one can read what the first one concluded.</dd></div>
</dl>

<h2 id="trust">What you have to trust</h2>
<p>Conversations are sensitive, so here is the honest version. Dex is open source, and by default everything stays on your Mac with no account at all. The hosted vault is optional and off until you sign in.</p>
<p>When it is on, secrets are stripped on your Mac and stripped again on the server. That is pattern matching and cannot catch everything. Notes are protected in transit but are <strong>not end-to-end encrypted</strong>, because the server has to read them to search them, and the person who runs the server can technically read them. Other users cannot. The <a href="{PRIVACY}">privacy notes</a> list exactly what is kept, and you can export or erase all of it from your account page.</p>

<h2 id="scale">How it grows</h2>
<p>The closed beta is deliberately small: invite only, capped at twenty people, 100 MB each, on a single machine. That is a choice, not a limit of the design. The plan is to grow by adding isolation before adding features.</p>
<ol class="steps">
<li><strong>Harden the base.</strong> A dedicated service account, off-site encrypted backups, uptime monitoring, and signed, notarized releases so app updates stop asking for permissions again.</li>
<li><strong>Move off one machine.</strong> Managed hosting, a database that handles many writers, and object storage for notes. Search gets an index instead of reading files, with optional semantic search.</li>
<li><strong>Take the operator out of the trust path.</strong> Per-user keys so that, by default, not even the person running the service can read your notes. Search over encrypted data is hard, so this one is research, not a promise.</li>
<li><strong>Run it yourself.</strong> The server is in the open repository, so a team that cannot send conversations to anyone else can host its own.</li>
</ol>

<h2 id="together">Many people, one session</h2>
<p>Everything above is about one person and their agents. The more interesting question is what happens when several people think together with several agents.</p>
<p>Today, if three of you use AI on the same problem, you have three private histories and a pile of pasted summaries. The goal is a single session that all of you contribute to, where each person brings their own agent, every contribution is labelled with who made it, and the result belongs to the group.</p>
{FIGURE}
<p>Making that work safely needs more than a shared folder. These are the pieces, in the order they would be built:</p>
<ul class="bullets">
<li><strong>Shared vaults with roles.</strong> A project vault with owners, contributors and readers. Your personal vault stays private; sharing is a decision you make per project.</li>
<li><strong>Attributed turns.</strong> Every message records who wrote it and which agent helped. Sessions are append-only, so two people typing at once never overwrite each other.</li>
<li><strong>Agent permissions.</strong> You choose what each agent may read and write, and writes into a shared session can require a person's approval.</li>
<li><strong>Presence and handoff.</strong> See who is in the session, pass the baton, and pick up where someone else stopped.</li>
<li><strong>An audit trail.</strong> A record of what every person and agent added, so a group can trust a session it did not watch.</li>
<li><strong>Redaction at the border.</strong> Secrets are removed before anything leaves a personal vault for a shared one.</li>
</ul>
<p>There are open questions we will not pretend away: how agents from different vendors should trust each other's output, how to split cost, and what to do when two people disagree with the same agent. We would rather learn those with a small group than guess.</p>

<h2 id="roadmap">The road from here</h2>
<ul class="roadmap">
<li><span class="chip is-done">Shipped</span><div><strong>Recorder and vault.</strong> Claude Code, Codex and Gemini conversations saved as notes, with secrets removed.</div></li>
<li><span class="chip is-done">Shipped</span><div><strong>Hosted memory and connector.</strong> Sign in by emailed link, a private vault per person, and a connector for Claude and ChatGPT.</div></li>
<li><span class="chip is-done">Shipped</span><div><strong>The notch.</strong> Mail that needs you, iPhone alerts, and reminders from a chat.</div></li>
<li><span class="chip is-now">Now</span><div><strong>Closed beta.</strong> Twenty invited people, feedback through the app, and hardening the service.</div></li>
<li><span class="chip is-next">Next</span><div><strong>Signed releases and managed hosting.</strong> Off-site backups, notarized builds, and a home that is not one machine.</div></li>
<li><span class="chip is-next">Next</span><div><strong>Delete and edit single notes.</strong> Control over one conversation, not only the whole account.</div></li>
<li><span class="chip is-later">Planned</span><div><strong>Shared vaults and multiplayer sessions.</strong> Roles, attributed turns, agent permissions and an audit trail.</div></li>
<li><span class="chip is-later">Planned</span><div><strong>Per-user encryption and self-hosting for teams.</strong></div></li>
</ul>
<p class="prose-foot">This is a plan, not a promise. Order and scope will change as people use it.</p>
</article>
</div>

<section class="section" aria-labelledby="read-cta">
<div class="wrap"><div class="cta-band reveal">
<span class="eyebrow">Early access</span>
<h2 id="read-cta">Want it to add up?</h2>
<p>Dex Notch is free during the closed beta and open source throughout.</p>
<div class="hero-actions">{cta}<a class="btn btn-ghost" href="{REPO}">Read the source</a></div>
</div></div>
</section>"""
    return layout("The long read", body, user=user, current="about",
                  description="Why AI work should add up: the problem with agents that forget, what Dex does about it, how it grows, and the plan for many people sharing one AI session.", fx=True)
