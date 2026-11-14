#!/usr/bin/env python3
"""Builds a synthetic vault (made-up projects, titles and a believable 10-week rhythm) for README screenshots and demos.
    python3 scripts/demo_vault.py /tmp/demo-vault  &&  NOTCH_VAULT=/tmp/demo-vault open NotchApp.app
Nothing here comes from a real vault."""
import json, random, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "memory"))
from agentvault.model import SessionMeta, Turn
from agentvault.notes import add_turns
from agentvault.index import rebuild_indexes

RNG = random.Random(7)
USED = {}
TITLES = {
    "atlas-api":     ["Fix N+1 query in the orders endpoint", "Add rate limiting to the public API", "Why does the webhook retry storm happen?", "Paginate the audit log", "Move session tokens to rotating refresh"],
    "pocket-notes":  ["Offline sync conflict resolution", "Markdown paste handling on iOS", "Design the share-sheet extension", "Speed up cold start"],
    "infra":         ["Terraform drift on the staging VPC", "Tune the Caddy gateway timeouts", "Backups: restore drill checklist", "Cloudflare tunnel for the build box"],
    "notch":         ["Sandboxed shell for the claude runner", "Heatmap sweep animation", "Model dial: keys and focus", "Keep the conversation across restarts", "Gemma answers with vault context"],
    "blog-redesign": ["Type scale for long-form posts", "Dark mode that doesn't glow", "OG image generator"],
    "ml-playground": ["Quantize the 12B model for the mini", "Eval harness for tool calling", "Why is first-token latency spiky?"],
}
AGENTS = {"claude-code": 0.46, "codex": 0.22, "gemini": 0.10, "gemma": 0.14, "chatgpt": 0.08}
SAY = ["Looked at the failing path first.", "Narrowed it to one function.", "Wrote the test, watched it fail, then fixed it.", "Checked the logs; the timeout was the cause.",
       "Proposed two options and picked the smaller one.", "Left a note about what is still open."]

def pick_agent():
    r, acc = RNG.random(), 0.0
    for a, w in AGENTS.items():
        acc += w
        if r <= acc: return a
    return "claude-code"

def build(vault: Path, now: datetime) -> int:
    n = 0
    pinned = {  # the newest chat per agent, so the "last chats" page reads well
        "claude-code": ("notch", "Sandboxed shell for the claude runner", 0, 9),
        "codex": ("atlas-api", "Add rate limiting to the public API", 0, 8),
        "gemini": ("infra", "Tune the Caddy gateway timeouts", 1, 15),
        "gemma": ("notch", "Gemma answers with vault context", 0, 11),
        "chatgpt": ("blog-redesign", "Type scale for long-form posts", 2, 13),
    }
    plan = [(agent, proj, title, off, hour) for agent, (proj, title, off, hour) in pinned.items()]
    for off in range(0, 70):
        day = now - timedelta(days=off)
        weekend = day.weekday() >= 5
        count = RNG.choice([0, 0, 1, 1]) if weekend else RNG.choice([1, 2, 2, 3, 4])
        if 20 < off < 27: count = 0                      # a quiet week
        if off in (3, 4, 10, 11, 12): count += 2          # bursts
        for _ in range(count):
            proj = RNG.choices(list(TITLES), weights=[5, 2, 3, 6, 2, 3])[0]
            least = min(USED.get(t, 0) for t in TITLES[proj])          # rotate through the titles so a day never repeats itself
            title = RNG.choice([t for t in TITLES[proj] if USED.get(t, 0) == least])
            USED[title] = USED.get(title, 0) + 1
            plan.append((pick_agent(), proj, title, off, RNG.randint(8, 22)))
    for i, (agent, proj, title, off, hour) in enumerate(plan):
        start = (now - timedelta(days=off)).replace(hour=hour, minute=RNG.randint(0, 59), second=0, microsecond=0)
        if start > now: start = now - timedelta(minutes=5 + i % 40)
        turns, t = [], start
        for k in range(RNG.randint(3, 16)):
            turns.append(Turn("user" if k % 2 == 0 else "assistant", title if k == 0 else RNG.choice(SAY), t.strftime("%Y-%m-%dT%H:%M:%SZ")))
            t += timedelta(minutes=RNG.randint(1, 4))
        meta = SessionMeta(agent, "%s%07x" % ("demo", RNG.getrandbits(28)) + "%02d" % (i % 100), proj, "/work/" + proj,
                           start.strftime("%Y-%m-%dT%H:%M:%SZ"), title, "demo")
        add_turns(vault, meta, turns); n += 1
    rebuild_indexes(vault)
    return n

if __name__ == "__main__":
    vault = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/demo-vault")
    now = datetime.now(timezone.utc)
    print("sessions:", build(vault, now))
    rec = vault / ".recorder"; rec.mkdir(parents=True, exist_ok=True)
    (rec / "status.json").write_text(json.dumps({"last_run": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "agents": {a: {"sessions": 1, "turns": 1, "state": "ok"} for a in AGENTS}, "errors": []}))
