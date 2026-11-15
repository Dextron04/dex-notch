#!/bin/bash
# Prints the GitHub release page for a tag: that version's section of CHANGELOG.md, then the install steps.
#   scripts/release-notes.sh v0.2.1
# Screenshots in the changelog are relative paths; on a release page they have to be absolute, pinned to the tag so they never change.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="$1"; NUM="${TAG#v}"
RAW="https://raw.githubusercontent.com/Dextron04/dex-notch/$TAG"
SECTION="$(awk -v n="$NUM" '/^## /{ if (on) exit; on = ($0 ~ "^## v" n "([: ]|$)") } on' CHANGELOG.md | sed '1d')"
[ -n "$SECTION" ] || { echo "CHANGELOG.md has no section for $TAG" >&2; exit 1; }
printf '%s\n' "$SECTION" | sed -E "s#(src=\"|\()docs/assets/#\1$RAW/docs/assets/#g; s#\]\(PRIVACY\.md\)#](https://github.com/Dextron04/dex-notch/blob/master/PRIVACY.md)#g"
sed "s/@TAG@/$TAG/g" docs/release-install.md
