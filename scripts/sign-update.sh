#!/bin/bash
# Signs the update zip made by make-dmg.sh, writes build/dist/appcast.xml and SHA256SUMS.txt. Its own script (and its own CI step) so the Sparkle private
# key is visible to nothing but this: the build, which runs far more code, never sees it.
#   scripts/sign-update.sh [version]
# The app only installs an update whose zip is signed with the private key that matches the public key inside it.
#   CI: SPARKLE_PRIVATE_KEY is a secret. Locally, SPARKLE_USE_KEYCHAIN=1 signs with the key `generate_keys` put in your Keychain.
#   SPARKLE_DOWNLOAD_BASE points the feed at another host (testing an update from a local server). With no key there is no feed, and this build is never offered as an update.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-dev}"
NUM="${VERSION#v}"; [[ "$NUM" =~ ^[0-9]+(\.[0-9]+)*$ ]] || NUM="0.0.0"
DIST="build/dist"; DD="build/release-dd"
[ -f "$DIST/dex-notch-$VERSION.zip" ] || { echo "no $DIST/dex-notch-$VERSION.zip: run scripts/make-dmg.sh first" >&2; exit 1; }

SIGN="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ] || [ -n "${SPARKLE_USE_KEYCHAIN:-}" ]; then
  [ -x "$SIGN" ] || { echo "sign_update not found at $SIGN" >&2; exit 1; }
  if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    KEYF="$(mktemp)"; chmod 600 "$KEYF"; printf %s "$SPARKLE_PRIVATE_KEY" > "$KEYF"
    SIGATTRS="$("$SIGN" --ed-key-file "$KEYF" "$DIST/dex-notch-$VERSION.zip")"; rm -f "$KEYF"
  else
    SIGATTRS="$("$SIGN" "$DIST/dex-notch-$VERSION.zip")"
  fi
  case "$SIGATTRS" in *edSignature=*) ;; *) echo "signing the update failed" >&2; exit 1 ;; esac
  scripts/appcast.sh "$VERSION" "$NUM" "${GITHUB_RUN_NUMBER:-1}" "$SIGATTRS" ${SPARKLE_DOWNLOAD_BASE:+"$SPARKLE_DOWNLOAD_BASE"} > "$DIST/appcast.xml"
else
  echo "no SPARKLE_PRIVATE_KEY: not writing appcast.xml, so this build will not be offered as an update" >&2
fi
( cd "$DIST" && shasum -a 256 dex-notch-"$VERSION".* > SHA256SUMS.txt )

echo "built:"; ls -lh "$DIST" | awk 'NR>1{print "  " $9, $5}'
