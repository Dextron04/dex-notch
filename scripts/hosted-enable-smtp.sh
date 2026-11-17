#!/bin/bash
# Switches the hosted service from "print sign-in links to the log" to real email, safely. Run on the mini: hosted-enable-smtp.sh YOUR_EMAIL
# 1) sends a real test mail through the saved key, 2) asks whether it arrived, 3) only then adds the --smtp flags to the launch agent and restarts.
# Needs the key in ~/agentvault-hosted/smtp-password (Resend: an API key with "sending access"). Override defaults with SMTP_HOST / SMTP_PORT / SMTP_USER / MAIL_FROM.
set -euo pipefail
TO=${1:?usage: $0 YOUR_EMAIL}
H=$HOME/agentvault-hosted; KEY=$H/smtp-password
PLIST=$HOME/Library/LaunchAgents/in.dextron04.agentvault-hosted.plist; LABEL=in.dextron04.agentvault-hosted
SMTP_HOST=${SMTP_HOST:-smtp.resend.com}; SMTP_PORT=${SMTP_PORT:-465}; SMTP_USER=${SMTP_USER:-resend}; MAIL_FROM=${MAIL_FROM:-Dex Notch <login@dextron04.in>}
URL=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -A1 -- '--public-url' | tail -1 | tr -d ' ')
[[ -s "$KEY" ]] || { echo "No key yet. Create it with:  umask 077; read -rs 'k?Paste key: '; echo; printf %s \"\$k\" > $KEY" >&2; exit 1; }
[[ "$(stat -f %Lp "$KEY")" == 600 ]] || { chmod 600 "$KEY"; echo "(tightened $KEY to owner-only)"; }
cd "$H/app"
/opt/homebrew/bin/python3 -m agentvault.hosted mail-test --public-url "$URL" --smtp-host "$SMTP_HOST" --smtp-port "$SMTP_PORT" --smtp-user "$SMTP_USER" --smtp-password-file "$KEY" --mail-from "$MAIL_FROM" "$TO"
if /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST" | grep -q -- '--smtp-host'; then echo "Already enabled in the launch agent; nothing to change."; exit 0; fi
read -r -p "Did the test email arrive in the inbox (not spam)? [y/N] " ok
[[ "$ok" == y || "$ok" == Y ]] || { echo "Not switching. Fix the domain/key and run this again; the service is unchanged." >&2; exit 1; }
cp "$PLIST" "$PLIST.bak-before-smtp"
for a in --smtp-host "$SMTP_HOST" --smtp-port "$SMTP_PORT" --smtp-user "$SMTP_USER" --smtp-password-file "$KEY" --mail-from "$MAIL_FROM"; do
  /usr/libexec/PlistBuddy -c "Add :ProgramArguments: string $a" "$PLIST"
done
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL"; sleep 1; launchctl bootstrap "gui/$(id -u)" "$PLIST"; sleep 3
[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8766/healthz)" == 200 ]] \
  && echo "Done: sign-in links are now emailed. (Rollback: restore $PLIST.bak-before-smtp, then bootout + bootstrap.)" \
  || { echo "Service didn't come up; rolling back." >&2; launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null; cp "$PLIST.bak-before-smtp" "$PLIST"; launchctl bootstrap "gui/$(id -u)" "$PLIST"; exit 1; }
