import argparse, sys, threading, time
from pathlib import Path
from .adapters import default_adapters
from . import hosted_sync, rag_push, recorder, remote_sync, reminder_stream, settings

RAG_EVERY = 600  # seconds between pushes of changed notes
REMOTE_EVERY = 300  # seconds between syncs with the remote connector host

class HostedLink:
    """Uploads to the hosted service and holds its reminder stream, whenever settings.json has a "hosted" section and the keychain has a device token.
    Re-read on every tick, so connecting or disconnecting in the app needs no restart."""
    def __init__(self, vault: Path, load=settings.load_hosted, push=hosted_sync.push):
        self.vault, self.load, self.push, self.cfg, self.stop, self.last_err = vault, load, push, None, None, ""

    def tick(self) -> None:
        cfg = self.load()
        if cfg != self.cfg:
            if self.stop: self.stop.set()                      # settings changed or removed: the old stream ends after its current wait
            self.cfg, self.stop = cfg, None
            if cfg:
                self.stop = threading.Event()
                threading.Thread(target=reminder_stream.run, args=(self.vault, cfg["base"], cfg["token"]),
                                 kwargs={"path": "/v1/reminders/wait", "stop": self.stop}, daemon=True).start()
        if not cfg: return
        try:
            s = self.push(self.vault, cfg["base"], cfg["token"])
            if s["turns"]: print("hosted: uploaded", s, flush=True)
            self.last_err = ""
        except Exception as e:
            if str(e) != self.last_err: print("hosted sync failed:", e, file=sys.stderr, flush=True)  # said once, not every 30s
            self.last_err = str(e)

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="agentvault", description="Record agent conversations into an Obsidian vault.")
    ap.add_argument("cmd", choices=["once", "run", "backfill", "import", "rag-sync", "remote-sync", "hosted-sync"])
    ap.add_argument("what", nargs="?", help="import: chatgpt")
    ap.add_argument("path", nargs="?", help="import: export folder, .zip or conversations.json (default: newest chatgpt export in ~/Downloads)")
    ap.add_argument("--vault", default="~/Vault")
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--reminders-url", help="the connector's public URL, for instant reminders (with --reminders-key-file)")
    ap.add_argument("--reminders-key-file")
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
    if a.cmd == "hosted-sync":
        cfg = settings.load_hosted()
        if not cfg: ap.error("no hosted connection: add a \"hosted\" host to settings.json and a device token to the keychain (Dex Notch > Settings)")
        try: print(hosted_sync.push(vault, cfg["base"], cfg["token"])); return 0
        except hosted_sync.HostedError as e: print("hosted-sync:", e, file=sys.stderr); return 1
    if a.cmd == "once":
        print(recorder.tick(vault, default_adapters(), wait=True)); return 0
    last_push = last_remote = 0.0
    if a.reminders_url and a.reminders_key_file:
        key = Path(a.reminders_key_file).expanduser().read_text().strip()
        threading.Thread(target=reminder_stream.run, args=(vault, a.reminders_url, key), daemon=True).start()
    link = HostedLink(vault)
    while True:  # run: never die on a bad tick
        try: recorder.tick(vault, default_adapters())
        except Exception as e: print("tick failed:", e, file=sys.stderr, flush=True)
        link.tick()
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
