#!/bin/sh
# Installs the recorder as a per-user launchd agent. Undo: launchctl bootout gui/$(id -u)/in.dextron04.agentvault
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
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
