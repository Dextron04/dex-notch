# Moving the hosted service to its own macOS user

**Why.** Today the hosted service runs as `mac-agent`, the same user as n8n, Paperclip, the browsers, the Claude app, a Lima VM and about ten other services. If any one of them is compromised it can read every tester's notes, `hosted.db` and the SMTP password. After this change only the service's own user (and root) can.

**What changes.** A hidden account `_dexhosted` (no password, no shell, cannot log in) owns `/var/dexhosted`, and the service runs as it from a LaunchDaemon. A daemon also starts at boot without anyone being logged in, which a LaunchAgent does not. The Cloudflare tunnel does not change: the service still listens on `127.0.0.1:8766`.

**You need:** a terminal on the mini (or `ssh -t mac-agent`) as an admin who can `sudo`. About 20 minutes; the service is down for about 2 of them. Nothing here is deleted until step 9.

---

## 1. Create the account and its group
Pick a UID that is free (`dscl . -list /Users UniqueID | awk '$2==450'` prints nothing). 450 is free on the mini today.

```
sudo dscl . -create /Groups/_dexhosted
sudo dscl . -create /Groups/_dexhosted PrimaryGroupID 450
sudo dscl . -create /Users/_dexhosted
sudo dscl . -create /Users/_dexhosted UniqueID 450
sudo dscl . -create /Users/_dexhosted PrimaryGroupID 450
sudo dscl . -create /Users/_dexhosted UserShell /usr/bin/false
sudo dscl . -create /Users/_dexhosted RealName "Dex hosted service"
sudo dscl . -create /Users/_dexhosted NFSHomeDirectory /var/dexhosted
sudo dscl . -create /Users/_dexhosted IsHidden 1
id _dexhosted        # uid=450(_dexhosted) gid=450(_dexhosted)
```
No password is set, so nobody can sign in as it.

## 2. Make its folders
```
sudo mkdir -p /var/dexhosted/data /var/dexhosted/logs /var/dexhosted/backups /var/dexhosted/app
sudo chown _dexhosted:_dexhosted /var/dexhosted /var/dexhosted/data /var/dexhosted/logs /var/dexhosted/backups
sudo chmod 700 /var/dexhosted /var/dexhosted/data /var/dexhosted/logs /var/dexhosted/backups
```

## 3. Stop the old service
(Downtime starts. The Mac app keeps working for up to 7 days without the server.)
```
launchctl bootout gui/$(id -u)/in.dextron04.agentvault-hosted
mv ~/Library/LaunchAgents/in.dextron04.agentvault-hosted.plist ~/agentvault-hosted/old-hosted.plist.disabled
pgrep -fl agentvault.hosted || echo stopped
```

## 4. Copy data, code and the SMTP password
```
sudo rsync -a ~/agentvault-hosted/data/ /var/dexhosted/data/
sudo rsync -a --delete --exclude __pycache__ ~/agentvault-hosted/app/ /var/dexhosted/app/
sudo install -m 600 -o _dexhosted -g _dexhosted ~/agentvault-hosted/smtp-password /var/dexhosted/smtp-password
sudo chown -R _dexhosted:_dexhosted /var/dexhosted/data
sudo chmod 600 /var/dexhosted/data/hosted.db*
# the code is owned by root on purpose: a compromised mac-agent must not be able to edit what runs as _dexhosted
sudo chown -R root:wheel /var/dexhosted/app && sudo chmod -R go-w /var/dexhosted/app
sudo -u _dexhosted sqlite3 /var/dexhosted/data/hosted.db "pragma integrity_check; select count(*) from users;"   # ok, then your user count
```

## 5. The LaunchDaemon
Use your own admin email for `--admin`. Change `--max-users` as you like.
```
sudo tee /Library/LaunchDaemons/in.dextron04.agentvault-hosted.plist >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>in.dextron04.agentvault-hosted</string>
<key>UserName</key><string>_dexhosted</string>
<key>GroupName</key><string>_dexhosted</string>
<key>WorkingDirectory</key><string>/var/dexhosted/app</string>
<key>EnvironmentVariables</key><dict><key>PYTHONDONTWRITEBYTECODE</key><string>1</string></dict>
<key>ProgramArguments</key><array>
<string>/opt/homebrew/bin/python3</string><string>-m</string><string>agentvault.hosted</string><string>serve</string>
<string>--root</string><string>/var/dexhosted/data</string>
<string>--public-url</string><string>https://vault.dextron04.in</string>
<string>--port</string><string>8766</string>
<string>--smtp-host</string><string>smtp.resend.com</string><string>--smtp-port</string><string>465</string>
<string>--smtp-user</string><string>resend</string>
<string>--smtp-password-file</string><string>/var/dexhosted/smtp-password</string>
<string>--mail-from</string><string>Dex Notch &lt;login@dextron04.in&gt;</string>
<string>--invite-only</string><string>--max-users</string><string>20</string>
<string>--admin</string><string>tushink04@gmail.com</string>
</array>
<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/var/dexhosted/logs/hosted.log</string>
<key>StandardErrorPath</key><string>/var/dexhosted/logs/hosted.log</string>
</dict></plist>
EOF
sudo chown root:wheel /Library/LaunchDaemons/in.dextron04.agentvault-hosted.plist
sudo chmod 644 /Library/LaunchDaemons/in.dextron04.agentvault-hosted.plist
plutil -lint /Library/LaunchDaemons/in.dextron04.agentvault-hosted.plist
```
Compare against the old plist (`plutil -p ~/agentvault-hosted/old-hosted.plist.disabled`) so no flag is lost. Add `--stripe-*` flags if you ever enabled Stripe.

## 6. Start it and check
```
sudo launchctl bootstrap system /Library/LaunchDaemons/in.dextron04.agentvault-hosted.plist
sleep 3
curl -s localhost:8766/healthz                                   # {"ok": true}
ps -o user=,args= -p "$(pgrep -f agentvault.hosted | head -1)" | cut -c1-60    # _dexhosted ...
tail -3 /var/dexhosted/logs/hosted.log 2>&1 || sudo tail -3 /var/dexhosted/logs/hosted.log
curl -s https://vault.dextron04.in/healthz
```
Then in a browser: sign in at `/login`, open `/admin`, send yourself an invite, and confirm the Mac app still shows as linked.

**The point of all this, as a test.** As `mac-agent` (not sudo) this must fail:
```
ls /var/dexhosted/data        # Permission denied
cat /var/dexhosted/smtp-password   # Permission denied
```

## 7. Backups
Move the nightly job to the new user.
```
sudo install -m 755 -o root -g wheel ~/agentvault-hosted/hosted-backup.sh /var/dexhosted/hosted-backup.sh
launchctl bootout gui/$(id -u)/in.dextron04.agentvault-hosted-backup 2>/dev/null
rm -f ~/Library/LaunchAgents/in.dextron04.agentvault-hosted-backup.plist
sudo tee /Library/LaunchDaemons/in.dextron04.agentvault-hosted-backup.plist >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>in.dextron04.agentvault-hosted-backup</string>
<key>UserName</key><string>_dexhosted</string><key>GroupName</key><string>_dexhosted</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>/var/dexhosted/hosted-backup.sh</string></array>
<key>EnvironmentVariables</key><dict>
<key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin</string>
<key>HOME</key><string>/var/dexhosted</string>
<key>HOSTED_ROOT</key><string>/var/dexhosted/data</string>
<key>HOSTED_BACKUPS</key><string>/var/dexhosted/backups</string>
<!-- off-machine copy, once you have one: <key>BACKUP_RSYNC_TARGET</key><string>user@host:dir</string> -->
</dict>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>15</integer></dict>
<key>StandardOutPath</key><string>/var/dexhosted/logs/backup.log</string>
<key>StandardErrorPath</key><string>/var/dexhosted/logs/backup.log</string>
</dict></plist>
EOF
sudo chown root:wheel /Library/LaunchDaemons/in.dextron04.agentvault-hosted-backup.plist && sudo chmod 644 /Library/LaunchDaemons/in.dextron04.agentvault-hosted-backup.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/in.dextron04.agentvault-hosted-backup.plist
sudo launchctl kickstart system/in.dextron04.agentvault-hosted-backup; sleep 5
sudo cat /var/dexhosted/logs/backup.log; sudo ls -l /var/dexhosted/backups     # "backup ok", an archive owned by _dexhosted
```

## 8. Reboot test
`sudo reboot`, wait two minutes without logging in, then `curl -s https://vault.dextron04.in/healthz`. It should answer. That also covers a power cut once `sudo pmset -a autorestart 1` is set.

## 9. Clean up after a week of normal use
The old copy is the thing this change exists to remove, so do not skip it.
```
rm -rf ~/agentvault-hosted/data ~/agentvault-hosted/backups ~/agentvault-hosted/smtp-password ~/agentvault-hosted/old-hosted.plist.disabled
rm -rf ~/agentvault-hosted/app ~/agentvault-hosted/app.bak-* ~/agentvault-hosted/plist.bak-*
```
Then **rotate the Resend API key** (it sat in a file `mac-agent` could read), put the new one in `/var/dexhosted/smtp-password`, and `sudo launchctl kickstart -k system/in.dextron04.agentvault-hosted`.

---

## Day to day after the move
| Task | Command |
|---|---|
| Deploy code | `rsync -a --delete --exclude __pycache__ agentvault tests mac-agent:/tmp/dex-deploy/` then `ssh -t mac-agent 'sudo rsync -a --delete /tmp/dex-deploy/ /var/dexhosted/app/ && sudo launchctl kickstart -k system/in.dextron04.agentvault-hosted'` (asks for the sudo password on purpose) |
| Restart | `sudo launchctl kickstart -k system/in.dextron04.agentvault-hosted` |
| Logs | `sudo tail -f /var/dexhosted/logs/hosted.log` |
| Stats, invites, grant | `sudo -u _dexhosted env PYTHONPATH=/var/dexhosted/app /opt/homebrew/bin/python3 -m agentvault.hosted stats --root /var/dexhosted/data` (same for `invite`, `invites`, `grant`) |
| See the waitlist | `sudo -u _dexhosted sqlite3 -header -column /var/dexhosted/data/hosted.db "select email,note,datetime(created,'unixepoch') joined,invited_at is not null invited from waitlist order by created"` |
| Restore a backup | stop the daemon, then `scripts/hosted-restore.sh ARCHIVE EMPTY_DIR` as `_dexhosted`, check it, move it into `/var/dexhosted/data`, start the daemon |

## Roll back
```
sudo launchctl bootout system/in.dextron04.agentvault-hosted
mv ~/agentvault-hosted/old-hosted.plist.disabled ~/Library/LaunchAgents/in.dextron04.agentvault-hosted.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/in.dextron04.agentvault-hosted.plist
```
Anything signed up since step 6 is only in `/var/dexhosted/data`; copy it back first (`sudo rsync -a /var/dexhosted/data/ ~/agentvault-hosted/data/`, then `sudo chown -R mac-agent ~/agentvault-hosted/data`).

## What this does not fix
- **The Python interpreter is still writable by `mac-agent`** (`/opt/homebrew` belongs to it). Someone who has already taken over `mac-agent` could replace it, and the service would run their code as `_dexhosted` at its next restart. Closing that needs a root-owned Python (for example the python.org installer in `/Library/Frameworks`, then point the plist at it). Worth doing before opening past the first testers.
- Notes are still plain files, protected by FileVault and by who can read them, not encrypted per user.
- Root, and anyone who can `sudo` on the mini, can still read everything.
