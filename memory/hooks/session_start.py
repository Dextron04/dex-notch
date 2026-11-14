#!/usr/bin/env python3
"""Claude Code SessionStart hook: prints a small digest of recent cross-agent activity.
Must never block or break a session: any error or a 2s overrun => print {} and exit 0."""
import json, os, signal, sys

def _bail(*_):
    print("{}"); sys.stdout.flush(); os._exit(0)

signal.signal(signal.SIGALRM, _bail); signal.alarm(2)
try:
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from agentvault.digest import build_digest
    try: cwd = json.load(sys.stdin).get("cwd", "") or os.getcwd()
    except Exception: cwd = os.getcwd()
    text = build_digest(Path(os.environ.get("AGENTVAULT_VAULT", "~/Vault")).expanduser(), cwd)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}} if text else {}))
except BaseException:
    print("{}")
sys.exit(0)
