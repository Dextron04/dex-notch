"""Keeps the remote connector's vault copy in step: push everything the recorder wrote, pull back what ChatGPT/Claude saved there.
`target` is any rsync destination: a local path or host:path."""
import subprocess
from pathlib import Path
from .index import rebuild_indexes

REMOTE_ORIGIN = ("chatgpt", "claude-web", "other-ai")  # written on the remote side; the laptop never overwrites these

def _rsync(*args: str) -> str:
    p = subprocess.run(["rsync", "-a", "-i", *args], capture_output=True, text=True, timeout=300)
    if p.returncode != 0: raise RuntimeError("rsync failed (%d): %s" % (p.returncode, p.stderr.strip()[:300]))
    return p.stdout

def pull_reminders(vault: Path, target: str) -> int:
    """Reminders set remotely (by ChatGPT/Claude) land in the laptop's vault, where the notch reads them. Cheap, so the daemon runs it every tick, not every few minutes."""
    try: out = _rsync("%s/Reminders/" % target.rstrip("/"), "%s/Reminders/" % Path(vault))
    except RuntimeError as e:
        if "No such file" in str(e) or "(23)" in str(e) or "(12)" in str(e): return 0     # nothing set yet
        raise
    return len([l for l in out.splitlines() if l[:2] in ("<f", ">f")])

def sync(vault: Path, target: str) -> dict:
    vault, target = Path(vault), target.rstrip("/")
    (vault / "Sessions").mkdir(parents=True, exist_ok=True)
    excl = [a for d in REMOTE_ORIGIN for a in ("--exclude", "/%s/" % d)]
    pushed = len([l for l in _rsync("--delete", *excl, "%s/Sessions/" % vault, "%s/Sessions/" % target).splitlines() if l[:2] in ("<f", ">f")])
    pulled = 0
    for d in REMOTE_ORIGIN:
        try: out = _rsync("%s/Sessions/%s/" % (target, d), "%s/Sessions/%s/" % (vault, d))
        except RuntimeError as e:
            if "No such file" in str(e) or "(23)" in str(e) or "(12)" in str(e): continue  # nothing saved from that source yet
            raise
        pulled += len([l for l in out.splitlines() if l[:2] in ("<f", ">f")])
    pulled += pull_reminders(vault, target)
    if pulled: rebuild_indexes(vault)
    return {"pushed": pushed, "pulled": pulled}
