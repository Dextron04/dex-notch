#!/bin/sh
# Installs the recorder as a per-user launchd agent. Undo: launchctl bootout gui/$(id -u)/in.dextron04.agentvault; python3 claude_hook.py remove
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_SET="$VAULT"
VAULT="${VAULT:-$HOME/Vault}"
PY="$(command -v python3)"
# REMOTE=host:path also syncs with the remote connector vault (see agentvault.remote_sync)
REMOTE_ARGS=""; [ -n "$REMOTE" ] && REMOTE_ARGS="<string>--remote</string><string>$REMOTE</string>"
PLIST="$HOME/Library/LaunchAgents/in.dextron04.agentvault.plist"
mkdir -p "$VAULT/.recorder" "$HOME/Library/LaunchAgents"
sed -e "s|__PYTHON__|$PY|g" -e "s|__VAULT__|$VAULT|g" -e "s|__MEMORY_DIR__|$DIR|g" -e "s|__REMOTE__|$REMOTE_ARGS|g" \
    "$DIR/launchd/in.dextron04.agentvault.plist.template" > "$PLIST"
launchctl bootout "gui/$(id -u)/in.dextron04.agentvault" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $PLIST (vault: $VAULT)"
# Claude Code opens briefed: register the start-up digest as a SessionStart hook (merged into ~/.claude/settings.json, backed up first).
# Skip with NO_HOOK=1. A non-default VAULT is passed on to the hook.
if [ -z "$NO_HOOK" ]; then
  if [ -n "$VAULT_SET" ]; then "$PY" "$DIR/claude_hook.py" add --vault "$VAULT_SET"; else "$PY" "$DIR/claude_hook.py" add; fi \
    || echo "could not register the Claude Code hook (see above); the recorder itself is installed"
fi
