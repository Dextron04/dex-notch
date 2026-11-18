---
name: dex-deploy
description: Deploy the Dex Notch hosted service (vault.dextron04.in) to the Mac mini, or check that a deploy worked. Use when asked to deploy, stage, push the server live, or verify the live site.
---

# Deploy the hosted service

The service runs on the Mac mini (`ssh mac-agent`) as the `_dexhosted` user from `/var/dexhosted/app`, as the LaunchDaemon `system/in.dextron04.agentvault-hosted`. `mac-agent` cannot write there or read the data. The last step needs the owner's **sudo password in a real Terminal**; the `!` prompt in Claude Code has no terminal and fails with "a terminal is required".

## Steps

1. **Test first.** `cd memory && python3 -m unittest discover -s tests` (about 95 s; run it in the background and read the result, don't poll). All must pass. For app changes also `xcodebuild test -project NotchApp.xcodeproj -scheme NotchApp -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
2. **Commit** only when the owner asks. Never add Claude as co-author or any "Generated with" line (the owner's global rule overrides the default attribution).
3. **Stage** (this part needs no sudo):
   ```
   cd memory
   ssh mac-agent 'mkdir -p /tmp/dex-deploy'
   rsync -a --delete --exclude __pycache__ agentvault tests mac-agent:/tmp/dex-deploy/
   ssh mac-agent 'cd /tmp/dex-deploy && /opt/homebrew/bin/python3 -m unittest discover -s tests -p "test_hosted*.py" 2>&1 | tail -4'
   ```
   Expected on the mini: only the three `test_hosted_backup` failures (they need the repo's `scripts/` folder) and one skipped test. Anything else is a real problem.
4. **Tell the owner to run**, in Terminal.app (not `!`):
   ```
   ssh -t mac-agent 'sudo rsync -a --delete /tmp/dex-deploy/ /var/dexhosted/app/ && sudo launchctl kickstart -k system/in.dextron04.agentvault-hosted'
   ```
   Say plainly what changes for users (see below) before they run it.
5. **Verify** once they say it's done: `scripts/verify-hosted.sh` (read-only; exits 1 on any failure). Then look at what the change touched by hand.

## Gotchas

- Check static files through the **versioned** URL the page links (`/static/app.css?v=...`). The bare `/static/app.css` is cached for a year at Cloudflare and shows an old copy.
- `ps -axo user,etime,args | grep agentvault.hosted` on the mini shows the user and uptime; uptime near zero means it restarted.
- Encryption is on by default (`--no-encryption` turns the requirement off). A deploy that first enables it pauses every Mac and assistant linked before an account locks its vault; they re-link by themselves, and `/admin` has an **Email them** button for accounts that haven't locked yet.
- Roll back by restoring the previous app folder from `/var/dexhosted` backups or by re-running the deploy from the previous commit; data and keys live outside `app/`.
- Never print or log tokens, recovery codes, passphrases or the owner's email. Never send the owner's email to an outside service without asking.
