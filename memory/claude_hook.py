#!/usr/bin/env python3
"""Add or remove the start-up digest as a Claude Code SessionStart hook in ~/.claude/settings.json.
Merges into what is there (never overwrites), is idempotent, and backs the file up before changing it.
  python3 claude_hook.py add [--settings FILE] [--vault DIR]      python3 claude_hook.py remove [--settings FILE]"""
import argparse, json, shlex, shutil, sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "hooks" / "session_start.py"
MARK = "hooks/session_start.py"      # how we recognise our own entry, wherever the checkout lives

def command(vault=None, python="python3"):
    env = f"AGENTVAULT_VAULT={shlex.quote(vault)} " if vault else ""
    return f"{env}{python} {shlex.quote(str(SCRIPT))}"

def _ours(group):
    return any(MARK in (h.get("command") or "") for h in group.get("hooks", []) if isinstance(h, dict))

def add(cfg, cmd):
    """True if cfg changed. An entry of ours already there is replaced in place, so moving the checkout updates it."""
    groups = cfg.setdefault("hooks", {}).setdefault("SessionStart", [])
    new = {"hooks": [{"type": "command", "command": cmd}]}
    for i, g in enumerate(groups):
        if isinstance(g, dict) and _ours(g):
            if g == new: return False
            groups[i] = new; return True
    groups.append(new); return True

def remove(cfg):
    groups = cfg.get("hooks", {}).get("SessionStart")
    if not isinstance(groups, list): return False
    keep = [g for g in groups if not (isinstance(g, dict) and _ours(g))]
    if len(keep) == len(groups): return False
    if keep: cfg["hooks"]["SessionStart"] = keep
    else:
        del cfg["hooks"]["SessionStart"]
        if not cfg["hooks"]: del cfg["hooks"]
    return True

def run(action, path, vault=None):
    """Returns a message. Raises ValueError (file untouched) if the settings file isn't a JSON object."""
    path = Path(path).expanduser()
    cfg = {}
    if path.exists() and path.read_text().strip():
        try: cfg = json.loads(path.read_text())
        except ValueError as e: raise ValueError(f"{path} is not valid JSON ({e}); left alone")
        if not isinstance(cfg, dict): raise ValueError(f"{path} is not a JSON object; left alone")
    try: changed = add(cfg, command(vault)) if action == "add" else remove(cfg)
    except (AttributeError, TypeError): raise ValueError(f"{path} has an unexpected 'hooks' shape; left alone")
    if not changed: return f"{path}: nothing to change"
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + ".dex-backup"))
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp"); tmp.write_text(json.dumps(cfg, indent=2) + "\n"); tmp.replace(path)
    return f"{path}: start-up digest hook {'installed' if action == 'add' else 'removed'}"

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("action", choices=["add", "remove"])
    ap.add_argument("--settings", default="~/.claude/settings.json"); ap.add_argument("--vault")
    a = ap.parse_args()
    try: print(run(a.action, a.settings, a.vault))
    except ValueError as e: print(e, file=sys.stderr); sys.exit(1)
