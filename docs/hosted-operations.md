# Hosted service: operations

Runs on the mini as `in.dextron04.agentvault-hosted` (port 8766, `https://vault.dextron04.in`). Code in `~/agentvault-hosted/app`, data in `~/agentvault-hosted/data` (`hosted.db` + `data/<user_id>/Vault`).

> **Isolation.** [hosted-isolation.md](hosted-isolation.md) moves the service to its own macOS user, `_dexhosted`. After that move, the paths and commands below change: data is `/var/dexhosted/data`, and deploys and CLI calls use sudo as that file shows.

## Deploy (manual; the GitHub auto-deploy only covers the personal connector)
```
cd memory
ssh mac-agent 'cp -R ~/agentvault-hosted/app ~/agentvault-hosted/app.bak-$(date +%Y%m%d%H%M%S)'
rsync -a --delete --exclude __pycache__ agentvault tests mac-agent:agentvault-hosted/app/
ssh mac-agent 'cd ~/agentvault-hosted/app && /opt/homebrew/bin/python3 -m unittest discover -s tests -p "test_hosted*.py" && launchctl kickstart -k gui/$(id -u)/in.dextron04.agentvault-hosted'
```
Roll back by moving `app.bak-*` back to `app` and kickstarting.

## Check it
- `curl https://vault.dextron04.in/healthz` is `{"ok": true}` (503 if the database can't be read). Point an uptime monitor at it.
- `tail ~/agentvault-hosted/logs/hosted.log`: one line per request (time, method, path, status); no queries, bodies or users.
- `python3 -m agentvault.hosted stats --root ~/agentvault-hosted/data`: accounts by status, devices, database size, largest vaults.

## Backups
`scripts/hosted-backup.sh` snapshots the database (integrity-checked) and all notes into `~/agentvault-hosted/backups/hosted-*.tar.gz` (owner-only), keeps the newest 14. Install: copy it to `~/agentvault-hosted/hosted-backup.sh` and load `memory/launchd/in.dextron04.agentvault-hosted-backup.plist.template` (nightly 03:15). **This is a copy on the same disk**: set `BACKUP_RSYNC_TARGET` to somewhere off the machine to survive a dead disk.

Restore (stop the service first): `scripts/hosted-restore.sh ARCHIVE EMPTY_DIR`, check its report, move the contents over `~/agentvault-hosted/data`, start the service.

## People
- Give someone access without Stripe: `python3 -m agentvault.hosted grant --root DIR EMAIL` (they must have signed in once).
- Erase long-canceled accounts: `python3 -m agentvault.hosted purge --root DIR --days 30` (dry run), then add `--yes`.
- A user can delete themselves from their account page; that cancels Stripe first and refuses if Stripe won't confirm.

## Closed beta
Add `--invite-only --max-users 20 --admin YOU@EMAIL` to the plist's `serve` arguments (bootout, then bootstrap). Then:
- Only existing accounts and invited emails can sign in. Everyone else sees the waitlist form at `/waitlist` (linked from the home and sign-in pages).
- A waiting address is **not** an invitation. The operator signs in, opens `/admin` (a 404 for everyone else), and presses **Invite** (or **Invite everyone waiting**). That adds the address to the allowlist and emails the download and sign-in link.
- CLI equivalents: `python3 -m agentvault.hosted invite|uninvite|invites --root DIR EMAIL...`.
- `--max-users` counts live accounts; a deleted account frees its place. Without `--smtp-*`, invitations are only written to the log.

## Known gaps
- Sign-in emails need `--smtp-*` flags; without them the link is printed to the log (only the operator can sign in).
- Notes are sealed on disk (`agentvault/seal.py`) with a per-account key wrapped by the person's passphrase, a recovery code, and each device or assistant token (`hosted/keys.py`). The server stores only wrapped copies, so the database and backups are ciphertext. A request opens the key for its own duration, so the operator is **not** locked out of a running service: say that, not more. `--no-encryption` turns the passphrase requirement off for local trials. Lose the passphrase and the recovery code and the notes are gone: there is no operator reset.
- Macs and assistants linked before an account locks its vault stop working at that moment and must be linked again (the app does this on its next launch or hourly check).
- Note names (agent, month, project, short id) stay readable on disk.
- No automatic purge schedule, no off-machine backup by default, no alerting beyond `/healthz`.
