"""The laptop's side of instant reminders: hold GET /reminders/wait open against the connector and write each reminder it hands back.
The connector answers the moment ChatGPT/Claude saves one (or after ~25s with nothing, and we ask again). Nothing has to reach into the laptop."""
import json, re, time, urllib.request
from pathlib import Path
from .notes import write_atomic

_NAME = re.compile(r"[0-9a-f]{16}\.md")

def store(vault: Path, files) -> int:
    """Writes what the connector sent into <vault>/Reminders. Only a plain `<16 hex>.md` name and a front-matter body are accepted: the reply is data, never a path."""
    n = 0
    for f in files if isinstance(files, list) else []:
        name, body = (f.get("name"), f.get("content")) if isinstance(f, dict) else (None, None)
        if not (isinstance(name, str) and _NAME.fullmatch(name) and isinstance(body, str) and body.startswith("---\n") and len(body) <= 4096): continue
        p = Path(vault) / "Reminders" / name
        if p.exists() and p.read_text(encoding="utf-8") == body: continue
        write_atomic(p, body); n += 1
    return n

def wait_once(base: str, key: str, after: str, timeout: float = 45, path: str = "/reminders/wait") -> dict:
    req = urllib.request.Request("%s%s?after=%s" % (base.rstrip("/"), path, after), headers={"Authorization": "Bearer " + key, "User-Agent": "agentvault-reminders/1"})   # Cloudflare turns away the default Python-urllib agent
    with urllib.request.urlopen(req, timeout=timeout) as r: return json.load(r)

def run(vault: Path, base: str, key: str, log=print, path: str = "/reminders/wait", stop=None) -> None:
    """Until `stop` is set (never, by default). A dropped connection or a sleeping laptop just means we ask again; the 30s pull catches anything missed meanwhile."""
    after, delay = "", 2
    while not (stop and stop.is_set()):
        try:
            d = wait_once(base, key, after, path=path)
            after, delay = str(d.get("token", after)), 2
            if store(vault, d.get("files")): log("reminders: received", flush=True)
        except Exception as e:
            log("reminder stream:", e, flush=True); time.sleep(delay); delay = min(delay * 2, 60)
