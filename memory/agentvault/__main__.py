import argparse, sys, time
from pathlib import Path
from .adapters import default_adapters
from . import rag_push, recorder, remote_sync, settings

RAG_EVERY = 600  # seconds between pushes of changed notes
REMOTE_EVERY = 300  # seconds between syncs with the remote connector host

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="agentvault", description="Record agent conversations into an Obsidian vault.")
    ap.add_argument("cmd", choices=["once", "run", "backfill", "import", "rag-sync", "remote-sync"])
    ap.add_argument("what", nargs="?", help="import: chatgpt")
    ap.add_argument("path", nargs="?", help="import: export folder, .zip or conversations.json (default: newest chatgpt export in ~/Downloads)")
    ap.add_argument("--vault", default="~/Vault")
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--remote", help="rsync target of the remote connector vault, e.g. mac-agent:agentvault/Vault")
    a = ap.parse_args(argv)
    vault = Path(a.vault).expanduser()
    if a.cmd == "backfill":
        s = recorder.backfill(vault, default_adapters()); print(s); return 1 if s["errors"] else 0
    if a.cmd == "import":
        from . import importers
        if a.what != "chatgpt": ap.error("import supports: chatgpt")
        src = Path(a.path) if a.path else importers.find_chatgpt_export()
        if not src: ap.error("no export found in ~/Downloads; pass the path")
        s = importers.import_chatgpt(vault, src); print(s); return 1 if s["errors"] else 0
    if a.cmd == "rag-sync":
        try: print(rag_push.sync(vault)); return 0
        except rag_push.PushError as e: print("rag-sync:", e, file=sys.stderr); return 1
    if a.cmd == "remote-sync":
        if not a.remote: ap.error("--remote required"); 
        print(remote_sync.sync(vault, a.remote)); return 0
    if a.cmd == "once":
        print(recorder.tick(vault, default_adapters(), wait=True)); return 0
    last_push = last_remote = 0.0
    while True:  # run: never die on a bad tick
        try: recorder.tick(vault, default_adapters())
        except Exception as e: print("tick failed:", e, file=sys.stderr, flush=True)
        if time.time() - last_push > RAG_EVERY and settings.load() is not None:  # keep the RAG in step (only once settings.json names a host); offline is fine, it retries next round
            last_push = time.time()
            try: print("rag:", rag_push.sync(vault), flush=True)
            except Exception as e: print("rag sync failed:", e, file=sys.stderr, flush=True)
        if a.remote and time.time() - last_remote > REMOTE_EVERY:  # unreachable host: retry next round
            last_remote = time.time()
            try: print("remote:", remote_sync.sync(vault, a.remote), flush=True)
            except Exception as e: print("remote sync failed:", e, file=sys.stderr, flush=True)
        if a.remote:  # a reminder is only useful on time: pull them on every tick, not every REMOTE_EVERY
            try:
                if remote_sync.pull_reminders(vault, a.remote): print("reminders: pulled", flush=True)
            except Exception as e: print("reminder pull failed:", e, file=sys.stderr, flush=True)
        time.sleep(a.interval)

if __name__ == "__main__":
    sys.exit(main())
