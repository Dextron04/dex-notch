#!/bin/bash
# Restore a hosted backup into an EMPTY folder, then check it. Usage: hosted-restore.sh ARCHIVE DEST
# Stop the service first, point it at DEST (or move DEST's contents into place), and start it again.
set -euo pipefail
[[ $# -eq 2 && -f "$1" ]] || { echo "usage: $0 ARCHIVE DEST" >&2; exit 2; }
if [[ -e "$2" && -n "$(ls -A "$2")" ]]; then echo "restore: $2 is not empty; refusing to overwrite anything" >&2; exit 1; fi
umask 077
mkdir -p "$2"
tar -xzf "$1" -C "$2"
[[ "$(sqlite3 "$2/hosted.db" 'PRAGMA integrity_check')" == ok ]] || { echo "restore: database failed its integrity check" >&2; exit 1; }
echo "restored $(sqlite3 "$2/hosted.db" 'SELECT COUNT(*) FROM users') user(s) and $(find "$2/data" -name '*.md' 2>/dev/null | wc -l | tr -d ' ') note(s) into $2"
