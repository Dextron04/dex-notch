import argparse, sys, time
from pathlib import Path
from .adapters import default_adapters
from . import rag_push, recorder

RAG_EVERY = 600  # seconds between pushes of changed notes

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="agentvault", description="Record agent conversations into an Obsidian vault.")
    ap.add_argument("cmd", choices=["once", "run", "backfill", "rag-sync"])
    ap.add_argument("--vault", default="~/Vault")
    ap.add_argument("--interval", type=int, default=30)
    a = ap.parse_args(argv)
    vault = Path(a.vault).expanduser()
    if a.cmd == "backfill":
        s = recorder.backfill(vault, default_adapters()); print(s); return 1 if s["errors"] else 0
    if a.cmd == "rag-sync":
        print(rag_push.sync(vault)); return 0
    if a.cmd == "once":
        print(recorder.tick(vault, default_adapters(), wait=True)); return 0
    last_push = 0.0
    while True:  # run: never die on a bad tick
        try: recorder.tick(vault, default_adapters())
        except Exception as e: print("tick failed:", e, file=sys.stderr, flush=True)
        if time.time() - last_push > RAG_EVERY:  # keep the mini's RAG in step; offline is fine, it retries next round
            last_push = time.time()
            try: print("rag:", rag_push.sync(vault), flush=True)
            except Exception as e: print("rag sync failed:", e, file=sys.stderr, flush=True)
        time.sleep(a.interval)

if __name__ == "__main__":
    sys.exit(main())
