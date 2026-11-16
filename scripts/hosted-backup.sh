#!/bin/bash
# Daily backup of the hosted service: a consistent SQLite snapshot plus every user's notes, in one private archive. Keeps the newest $KEEP.
# Optional second copy off this machine: BACKUP_RSYNC_TARGET=user@host:dir (the archive holds private chats: send it only somewhere you trust).
set -euo pipefail
ROOT=${HOSTED_ROOT:-$HOME/agentvault-hosted/data}
OUT=${HOSTED_BACKUPS:-$HOME/agentvault-hosted/backups}
KEEP=${KEEP:-14}
umask 077
mkdir -p "$OUT"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sqlite3 "$ROOT/hosted.db" ".backup '$tmp/hosted.db'"       # safe while the service is writing, unlike copying the file
[[ "$(sqlite3 "$tmp/hosted.db" 'PRAGMA integrity_check')" == ok ]] || { echo "backup: database failed its integrity check, nothing saved" >&2; exit 1; }
name=hosted-$(date +%Y%m%d-%H%M%S).tar.gz
if [[ -d "$ROOT/data" ]]; then tar -czf "$tmp/$name" -C "$tmp" hosted.db -C "$ROOT" data; else tar -czf "$tmp/$name" -C "$tmp" hosted.db; fi
mv "$tmp/$name" "$OUT/$name"
[[ -z "${BACKUP_RSYNC_TARGET:-}" ]] || rsync -a "$OUT/$name" "$BACKUP_RSYNC_TARGET/"
ls -1t "$OUT"/hosted-*.tar.gz | tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done
echo "$(date '+%F %T') backup ok: $name ($(du -h "$OUT/$name" | cut -f1))"
