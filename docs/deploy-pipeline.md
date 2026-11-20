# Deploy pipeline (pull-based)

The Mac mini deploys the Dex Notch servers by itself: it **pulls** master from GitHub when CI is green. Nothing in GitHub can reach the mini, the mini holds no GitHub secret, and there is no self-hosted runner (the repo is public, so a fork's pull request must never be able to run code there).

Two targets use the same script, `scripts/dex-deployer.sh`, with one config file each in `scripts/deploy-targets/`:

| | hosted | personal |
|---|---|---|
| site | vault.dextron04.in | memory.dextron04.in |
| service | `system/in.dextron04.agentvault-hosted` (LaunchDaemon, user `_dexhosted`) | `gui/<uid>/in.dextron04.agentvault-remote` (LaunchAgent, `mac-agent`) |
| deploy tree (releases, `current`, logs, state) | `/var/dexhosted-deploy` (root:wheel 755; the service data and logs stay in `/var/dexhosted`) | `~/agentvault` |
| deployer runs as | root, every 120 s (`in.dextron04.dex-deployer-hosted`) | `mac-agent`, every 120 s (`in.dextron04.dex-deployer-personal`) and on the `/hooks/deploy` webhook |
| health | `GET :8766/healthz` 200, `POST :8766/mcp` 401 | `POST :8765/mcp` 401 |

## How it works

```
 launchd (every 120 s) / webhook
            |
            v
   dex-deployer.sh TARGET.conf
            |
 [base tree sane?]--no--> refuse   real dirs, no symlinks, root-owned (hosted), not group/world-writable
            |
 [paused?]--yes--> exit          <base>/deploy-paused
            | no
 [lock: mkdir <base>/.deploy.lock]--held--> exit
            |
 GitHub API (no token, custom User-Agent, ETag => a 304 is free)
   head sha of master == <base>/deploy-seen ? --yes--> exit
   check-run "test" (GitHub Actions) for that sha
      pending/none --> exit, look again later
      not success  --> log "skip", record sha, exit
            |
 download /tarball/<sha> into <base>/tmp/work.XXXX   (top dir must carry the sha; no links in it)
   source dir hash == current release's hash ? --yes--> record, exit
            |
 run `python -E -s -m unittest discover -s tests` (the root-owned interpreter below) from memory/ of the test copy (whole tree minus heavy assets) as the service user
   (sudo -u _dexhosted, empty env, timeout; code root-owned and read-only to it,
   TMPDIR and HOME in a separate work/state dir that only that user deletes)   fail --> REJECTED, record, exit
            |
 unpack memory/agentvault -> <base>/releases/<UTC>-<sha7>/agentvault   (read-only; root-owned for hosted)
            |
 ln -sfn tmp-link ; mv -fh tmp-link <base>/current        (atomic switch)
 launchctl kickstart -k <domain>/<label>
            |
 health checks, retried ~30 s
    ok   --> record "deployed", prune old releases (keep 5, never current or previous)
    fail --> current -> previous release, kickstart, re-check, log "ROLLED BACK <reason>", notify
```

The service runs with its working directory (and so its import path) at `<base>/current`, which holds `agentvault/`. A deploy never edits files in place: it adds a release and moves one symlink.

Every step is logged with a UTC timestamp to `<base>/logs/deploy.log`. State: `<base>/deploy-seen` holds `<sha> <status> <etag>` for the last head it handled. A sha that was deployed, rejected or skipped is never retried; delete the file to force a retry.

Rate limits: unauthenticated GitHub calls allow 60 an hour per IP. The deployer sends `If-None-Match` with the stored ETag, and a 304 does not count, so an idle poll costs nothing. Do not poll more often than every 2 minutes.

Limits worth knowing:
- A sha whose CI failed is recorded and not retried, even if CI is re-run green later. `rm <base>/deploy-seen` to retry.
- The mini only deploys what is on master with a green `test` job. Anyone who can push to master can ship code there; protect the branch.
- **Root never works inside a directory the service owns.** `/var/dexhosted` (owned by `_dexhosted`) holds only the service's data and logs. Everything root reads, writes, switches or deletes lives in `/var/dexhosted-deploy`, owned by root. The service gets read access to the code, nothing else. Otherwise a compromised service could swap `releases` or `tmp` for a symlink to `/etc` or a home folder and let root's `rm -rf` or `mv` follow it.
- **Defence in depth in the script (both targets).** At start, before pruning, and before switching, it checks that the base, `logs`, `releases`, `tmp` and every release dir are real directories (no symlinks), owned by the running user and not group- or world-writable, and, as root, that every ancestor of the base is too. If not it refuses (exit 2) and logs. `rm -rf` runs only on `<base>/releases/<name>` or its own `<base>/tmp/work.*`, right after its parent was checked. The test step's writable state is a separate directory owned by the service user, deleted by that user (`sudo -u`), so root never walks into it. Tarballs that contain links are rejected. Residual: the personal target runs as `mac-agent`, which owns everything under `~/agentvault`, so the checks there guard against mistakes and other users, not against `mac-agent` itself.
- **The installer never writes into the personal user's tree as root.** `chown`, `chmod`, `>` and `cp` follow symlinks, and `mac-agent` could plant `deploy-paused -> /etc/sudoers`. Everything under `~/agentvault` and `~/Library/LaunchAgents` is done by `sudo -u mac-agent` (the installer re-runs a root-installed copy of itself with `--personal-files`), and that mode refuses to run as root and refuses planted symlinks. The hosted migration copies the service-owned old app dir by reading it as that user (`tar | tar`) and aborts if the copy contains any link.
- Tests run from a read-only, root-owned copy of the whole tarball tree (`<copy>/memory` is the working dir), not just `memory/`: several tests run `REPO_ROOT/scripts/*.sh` or read `PRIVACY.md` and `docs/*.md`. Only heavy assets tests never read are left out: `docs/assets/`, `katana-assets/`, `*.xcodeproj`, `*.mp4`, `*.zip` (small PNGs stay: the hosted pages tests serve them). The release still gets only `src_subdir`. A test that writes into its own source tree fails and blocks the deploy (the suite passes in a read-only tree today).
- `notify=osascript` in a config shows a macOS notification on rollback or rejection, but a root daemon has no GUI session, so it is mostly useful for the personal target. `notify=/path/to/cmd` runs `cmd "message"` (no shell), e.g. a script that sends mail.

## The root-owned Python runtime

**Why.** Root and `_dexhosted` must never execute anything a less-privileged user can replace. `/opt/homebrew` belongs to `mac-agent` (the personal connector, Docker, n8n and every dev tool run as that user), so a Homebrew `python3` or `curl` on root's PATH was a path from `mac-agent` to root within 120 s, and to every hosted user's data through `_dexhosted`. Now:

- The deployer's PATH is `/usr/bin:/bin:/usr/sbin:/sbin` (script, both plist templates and the installer). `curl`, `tar`, `sudo` and `launchctl` are called by absolute path.
- Python comes from `python=` in the target config. For hosted: `/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14`, from the official python.org installer (3.14.10). It is a real file, not a symlink. Why not the Command Line Tools Python 3.9: it lacks `hashlib.scrypt` (the vault key derivation) and the hosted tests fail on it. Why not a copied Homebrew interpreter: its dylib paths point back into `/opt/homebrew`.
- **The deployer refuses to run (exit 2)** if the interpreter or any directory above it is a symlink, is not owned by root, or is group- or world-writable. It parses GitHub's JSON with that interpreter (`-I`) and runs the tests as `_dexhosted` with it (`-E -s`, an empty environment, PATH = its own bin dir + system dirs). A non-root run (the personal target, whose Homebrew Python belongs to its own user) only needs an executable file.
- Test seam, ignored when running as root: `DEX_TRUST_UID` (owner to trust instead of 0) and `DEX_TRUST_ANCHOR` (where the walk up the path stops), so CI as a normal user can exercise the checks.

**The python.org pkg makes the framework group-`admin`-writable** (its postinstall runs `chgrp -R admin; chmod -R g+w`), and `mac-agent` is in `admin`. `install-deployer.sh` therefore always finishes with `chown -R root:wheel` and `chmod -R go-w` on the framework, and re-checks the chain. Re-run it after anything that touches the framework (an upgrade, `pip install` into it: do not do that).

**What the installer does about it** (idempotent): downloads the pinned pkg over https, requires its SHA-256 to match the value committed in `scripts/install-deployer.sh` and `pkgutil --check-signature` to show Developer ID Installer: Python Software Foundation (BMM5U3QVKW), then installs only the Python framework (no GUI apps, no `/usr/local/bin` links, no docs, no shell profile edits, no pip). It rewrites the hosted daemon plist's `ProgramArguments[0]` (backup in `/var/dexhosted-deploy/backups/`), restarts the service once, and checks `GET :8766/healthz` is 200 and `POST :8766/mcp` is 401; on failure it puts the old plist back and restarts. It also removes `/opt/homebrew/bin` from the nightly backup job's PATH, and prints the interpreter's ownership chain.

**Upgrading Python safely.** Pick the new release on python.org (same minor is a drop-in; a new minor changes the path). Download the `macos11.pkg` on a trusted machine, run `shasum -a 256` and `pkgutil --check-signature` on it, edit `PY_VER`, `PY_MINOR`, `PY_URL`, `PY_SHA256` in `scripts/install-deployer.sh` and `python=` in `scripts/deploy-targets/hosted.conf`, let CI pass (the deployer will deploy the new conf only after the installer copies it, so the old interpreter keeps working until then), then `sudo scripts/install-deployer.sh`. The old `Versions/3.X` directory is left in place; delete it once the new one is healthy.

## Install (once, on the mini)

From a checkout of master on the mini (or after `rsync`ing the repo there):

```
cd <checkout> && sudo scripts/install-deployer.sh
```

It copies the scripts and configs to `/usr/local/dex-deployer` (root:wheel, 755/644), creates `/var/dexhosted-deploy` and migrates both layouts (below), changes the hosted daemon's `WorkingDirectory` (and `PYTHONPATH`, if set) to `/var/dexhosted-deploy/current` (it prints the plist diff and backs the original up to `/var/dexhosted-deploy/backups/`), installs the root-owned Python (see above), switches the daemon to it, installs the two deployer plists, bootstraps them (retrying once, because launchd often returns "5: Input/output error" right after a bootout), and prints a summary. The hosted service restarts once (a few seconds) for the plist change.

It does not deploy. A fresh install leaves each target **paused** (`<base>/deploy-paused`). To go live: `sudo scripts/install-deployer.sh --deploy-now`, or `rm /var/dexhosted-deploy/deploy-paused ~mac-agent/agentvault/deploy-paused`. Safe to re-run any time. `--skip-personal` installs only the hosted side.

Everything the deployer needs is in the repo (scripts, configs, plist templates, this page), so a wiped home folder costs nothing but re-running the installer.

## The migration (inside the installer, idempotent)

**Hosted.** Today `/var/dexhosted/app` is a plain directory owned by the service user. The installer:

1. does nothing if `/var/dexhosted-deploy/current` is already a symlink;
2. copies `/var/dexhosted/app` to `/var/dexhosted-deploy/backups/pre-deployer-<UTC>/app`;
3. copies it (without `__pycache__`) to `/var/dexhosted-deploy/releases/<UTC>-initial`, root-owned, 644/755, and sets `current -> releases/<UTC>-initial`;
4. updates the daemon plist and restarts the service, then renames the old directory to `/var/dexhosted/app.replaced-<UTC>` (never deleted; remove it yourself later).

There is **no** compatibility symlink at `/var/dexhosted/app`: the plist now points at `current`, and nothing else reads the old path. (Old notes that mention `/var/dexhosted/app`, such as `hosted-isolation.md`, describe the pre-pipeline layout.)

**Personal.** `~/agentvault/app` is a plain directory. The installer backs it up to `~/agentvault/backups/pre-deployer-<UTC>/app`, moves it to `~/agentvault/releases/<UTC>-initial`, sets `current -> that release` and `app -> current`. The `app` symlink is deliberate: the connector's plist (WorkingDirectory `/Users/mac-agent/agentvault/app`) keeps working unedited.

The first real deploy replaces the "initial" release. `scripts/install-deployer.sh --migrate-only BASE` (personal-style move) and `--migrate-copy OLD_APP BASE` (hosted-style copy) run just these steps.

## The webhook (personal)

The connector's `POST /hooks/deploy` runs `/bin/zsh ~/agentvault/connector-deploy.sh` with `DEPLOY_HOOK=1` (hardcoded in `memory/agentvault/remote/__main__.py`). So `scripts/connector-deploy.sh` stays as a three-line zsh wrapper that `exec`s the new bash deployer for the personal target; the installer copies it to `~/agentvault/connector-deploy.sh`. The old 5-minute poller `in.dextron04.agentvault-deploy` is bootout'd and its plist renamed `.disabled-<stamp>`. With `DEPLOY_HOOK` set the deployer also logs why it stopped (`hook: ...`).

## Pause, roll back, logs

- **Pause:** `touch <base>/deploy-paused` (the script checks it before doing anything). `rm` it to resume. Use it before hand-fixing a release.
- **Roll back by hand:**
  ```
  ls -1 /var/dexhosted-deploy/releases                 # newest last; current:  readlink /var/dexhosted-deploy/current
  sudo touch /var/dexhosted-deploy/deploy-paused
  sudo ln -sfn releases/<previous-release> /var/dexhosted-deploy/.cur.tmp && sudo mv -fh /var/dexhosted-deploy/.cur.tmp /var/dexhosted-deploy/current
  sudo launchctl kickstart -k system/in.dextron04.agentvault-hosted
  scripts/verify-hosted.sh
  ```
  Personal: same without `sudo`, base `~/agentvault`, `launchctl kickstart -k gui/$(id -u)/in.dextron04.agentvault-remote`. (`ln -sfn` straight onto `current` also works but is not atomic.)
- **Logs:** `<base>/logs/deploy.log` (hosted: `sudo tail -50 /var/dexhosted-deploy/logs/deploy.log`); launchd's own stderr for the deployer is `<base>/logs/deployer.err`. Look for `deployed`, `REJECTED`, `skip`, `ROLLED BACK`.
- **Emergency manual deploy** still works: [hosted-operations.md](hosted-operations.md). Pause the deployer first, or it may switch `current` underneath you.

## Tests

`memory/tests/test_deployer.py` runs the real script against a temp base, a fake GitHub API and a stub `launchctl` that restarts a tiny fake service. It covers: green deploy, CI not green, failing tests, failing health with rollback, the same sha twice, pruning, refusing an empty or `/` base, the lock, the pause file, `releases`, `tmp`, `logs`, a release dir and the base swapped for symlinks to an outside dir (refused, outside dir untouched), a world-writable base, and the migrations. It also covers the interpreter checks (wrong owner, writable parent or file, symlinks, outside the trusted tree, missing), the absence of bare `python3` and Homebrew in the script, installer and plist PATHs, and the installer refusing planted symlinks. Actual root ownership needs root and is not exercised in CI (the seam stands in for it). Test hooks in the script: `DEX_API_URL`, `DEX_LAUNCHCTL`, `DEX_TIMESTAMP`, `DEX_TRUST_UID`, `DEX_TRUST_ANCHOR`.
