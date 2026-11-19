# Deploy pipeline (pull-based)

The Mac mini deploys the Dex Notch servers by itself: it **pulls** master from GitHub when CI is green. Nothing in GitHub can reach the mini, the mini holds no GitHub secret, and there is no self-hosted runner (the repo is public, so a fork's pull request must never be able to run code there).

Two targets use the same script, `scripts/dex-deployer.sh`, with one config file each in `scripts/deploy-targets/`:

| | hosted | personal |
|---|---|---|
| site | vault.dextron04.in | memory.dextron04.in |
| service | `system/in.dextron04.agentvault-hosted` (LaunchDaemon, user `_dexhosted`) | `gui/<uid>/in.dextron04.agentvault-remote` (LaunchAgent, `mac-agent`) |
| base dir | `/var/dexhosted` | `~/agentvault` |
| deployer runs as | root, every 120 s (`in.dextron04.dex-deployer-hosted`) | `mac-agent`, every 120 s (`in.dextron04.dex-deployer-personal`) and on the `/hooks/deploy` webhook |
| health | `GET :8766/healthz` 200, `POST :8766/mcp` 401 | `POST :8765/mcp` 401 |

## How it works

```
 launchd (every 120 s) / webhook
            |
            v
   dex-deployer.sh TARGET.conf
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
 download /tarball/<sha> into <base>/tmp/work.XXXX   (top dir must carry the sha)
   source dir hash == current release's hash ? --yes--> record, exit
            |
 run `python3 -m unittest discover -s tests` from memory/ as the service user
   (sudo -u _dexhosted, empty env, timeout)   fail --> REJECTED, record, exit
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
- On hosted, `/var/dexhosted` is owned by `_dexhosted`, so a compromised service could repoint `current` (it could already edit its own code before this). Release files themselves are root-owned and read-only.
- `notify=osascript` in a config shows a macOS notification on rollback or rejection, but a root daemon has no GUI session, so it is mostly useful for the personal target. `notify=/path/to/cmd` runs `cmd "message"` (no shell), e.g. a script that sends mail.

## Install (once, on the mini)

From a checkout of master on the mini (or after `rsync`ing the repo there):

```
cd <checkout> && sudo scripts/install-deployer.sh
```

It copies the scripts and configs to `/usr/local/dex-deployer` (root:wheel, 755/644), migrates both layouts (below), changes the hosted daemon's `WorkingDirectory` to `/var/dexhosted/current` (it prints the plist diff and backs the original up to `/var/dexhosted/backups/`), installs the two deployer plists, bootstraps them (retrying once, because launchd often returns "5: Input/output error" right after a bootout), and prints a summary. The hosted service restarts once (a few seconds) for the plist change.

It does not deploy. A fresh install leaves each target **paused** (`<base>/deploy-paused`). To go live: `sudo scripts/install-deployer.sh --deploy-now`, or `rm /var/dexhosted/deploy-paused ~mac-agent/agentvault/deploy-paused`. Safe to re-run any time. `--skip-personal` installs only the hosted side.

Everything the deployer needs is in the repo (scripts, configs, plist templates, this page), so a wiped home folder costs nothing but re-running the installer.

## The migration (inside the installer, idempotent)

Today `/var/dexhosted/app` and `~/agentvault/app` are plain directories. For each base the installer:

1. does nothing if `<base>/current` is already a symlink;
2. copies `<base>/app` to `<base>/backups/pre-deployer-<UTC>/app`;
3. creates `<base>/current -> releases/<UTC>-initial`, moves `<base>/app` to `<base>/releases/<UTC>-initial` (an atomic rename on the same disk; the running process keeps its open working directory), and makes `<base>/app -> current`.

`app -> current` is deliberate: anything still pointing at the old path (the personal connector's launchd plist and its `sys.path.insert(BASE/app)`, which are not in the repo) keeps working with no edit. The hosted plist is updated to `current` anyway. The first real deploy replaces the "initial" release. `scripts/install-deployer.sh --migrate-only BASE` runs just this step.

## The webhook (personal)

The connector's `POST /hooks/deploy` runs `/bin/zsh ~/agentvault/connector-deploy.sh` with `DEPLOY_HOOK=1` (hardcoded in `memory/agentvault/remote/__main__.py`). So `scripts/connector-deploy.sh` stays as a three-line zsh wrapper that `exec`s the new bash deployer for the personal target; the installer copies it to `~/agentvault/connector-deploy.sh`. The old 5-minute poller `in.dextron04.agentvault-deploy` is bootout'd and its plist renamed `.disabled-<stamp>`. With `DEPLOY_HOOK` set the deployer also logs why it stopped (`hook: ...`).

## Pause, roll back, logs

- **Pause:** `touch <base>/deploy-paused` (the script checks it before doing anything). `rm` it to resume. Use it before hand-fixing a release.
- **Roll back by hand:**
  ```
  ls -1 /var/dexhosted/releases                 # newest last; current:  readlink /var/dexhosted/current
  sudo touch /var/dexhosted/deploy-paused
  sudo ln -sfn releases/<previous-release> /var/dexhosted/.cur.tmp && sudo mv -fh /var/dexhosted/.cur.tmp /var/dexhosted/current
  sudo launchctl kickstart -k system/in.dextron04.agentvault-hosted
  scripts/verify-hosted.sh
  ```
  Personal: same without `sudo`, base `~/agentvault`, `launchctl kickstart -k gui/$(id -u)/in.dextron04.agentvault-remote`. (`ln -sfn` straight onto `current` also works but is not atomic.)
- **Logs:** `<base>/logs/deploy.log` (hosted: `sudo tail -50 /var/dexhosted/logs/deploy.log`); launchd's own stderr for the deployer is `<base>/logs/deployer.err`. Look for `deployed`, `REJECTED`, `skip`, `ROLLED BACK`.
- **Emergency manual deploy** still works: [hosted-operations.md](hosted-operations.md). Pause the deployer first, or it may switch `current` underneath you.

## Tests

`memory/tests/test_deployer.py` runs the real script against a temp base, a fake GitHub API and a stub `launchctl` that restarts a tiny fake service. It covers: green deploy, CI not green, failing tests, failing health with rollback, the same sha twice, pruning, refusing an empty or `/` base, the lock, the pause file and the migration. Test hooks in the script: `DEX_API_URL`, `DEX_LAUNCHCTL`, `DEX_TIMESTAMP`.
