#!/bin/bash
# Builds "Dex Notch.app" (universal, ad-hoc signed) and packages it as a .dmg and a .zip in build/dist/.
#   scripts/make-dmg.sh [version]        e.g. scripts/make-dmg.sh v0.1.0
# Ad-hoc signing means macOS blocks the first launch until it is allowed once (Privacy & Security > Open Anyway on macOS 15+). Notarizing needs a paid
# Apple Developer ID; see the README's install section.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-dev}"
NUM="${VERSION#v}"; [[ "$NUM" =~ ^[0-9]+(\.[0-9]+)*$ ]] || NUM="0.0.0"
DIST="build/dist"; STAGE="build/dmg-stage"; DD="build/release-dd"
rm -rf "$DIST" "$STAGE" "$DD"; mkdir -p "$DIST" "$STAGE"

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate >/dev/null

xcodebuild -scheme NotchApp -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$DD" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}" \
  PRODUCT_NAME="Dex Notch" MARKETING_VERSION="$NUM" CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGNING_ALLOWED=YES \
  ${SPARKLE_FEED_URL:+SPARKLE_FEED_URL="$SPARKLE_FEED_URL"} \
  build > "$DD.log" 2>&1 || { grep -E "error:" "$DD.log" | sort -u | head -20 >&2; tail -n 5 "$DD.log" >&2; exit 1; }
tail -n 3 "$DD.log"

APP="$DD/Build/Products/Release/Dex Notch.app"; BIN="$APP/Contents/MacOS/Dex Notch"
[ -d "$APP" ] || { echo "build did not produce $APP" >&2; exit 1; }

# the signature must be valid and the binary must really be universal, or the DMG is not worth shipping
codesign --verify --deep --strict "$APP"
lipo -archs "$BIN" | grep -q arm64 && lipo -archs "$BIN" | grep -q x86_64 \
  || { echo "binary is not universal: $(lipo -archs "$BIN")" >&2; exit 1; }

# nothing but the app itself may ship: no tooling folders, logs or data files that slipped in from a messy working tree
STRAY=$(find "$APP" \( -name ".claude-flow" -o -name ".swarm" -o -name ".superpowers" -o -name "patterns.json" -o -name "*.log" -o -name ".env*" -o -name "*.jsonl" \) | head -5)
[ -z "$STRAY" ] || { echo "refusing to package: unexpected files inside the app:" >&2; echo "$STRAY" >&2; exit 1; }
WANT="$NUM"; GOT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$GOT" = "$WANT" ] || { echo "version in the app is $GOT, expected $WANT" >&2; exit 1; }

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<TXT
Dex Notch $VERSION

1. Drag Dex Notch into Applications.
2. Open it once. This build is not notarized, so macOS says it can't verify the app:
     macOS 15 and later: System Settings > Privacy & Security > scroll down > Open Anyway.
     macOS 14: right-click the app and choose Open.
     Any version, from Terminal:  xattr -dr com.apple.quarantine "/Applications/Dex Notch.app"
3. A setup window opens. Pick Claude or Codex (install one first if you have neither), choose where it may work, and press Save and start.
4. Press Option+Space.

https://github.com/Dextron04/dex-notch
TXT

hdiutil create -volname "Dex Notch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/dex-notch-$VERSION.dmg" >/dev/null
ditto -c -k --keepParent "$APP" "$DIST/dex-notch-$VERSION.zip"
hdiutil verify "$DIST/dex-notch-$VERSION.dmg" >/dev/null

# The update feed. The app only installs an update whose zip is signed with the private key that matches the public key inside it.
#   CI: SPARKLE_PRIVATE_KEY is a secret. Locally, SPARKLE_USE_KEYCHAIN=1 signs with the key `generate_keys` put in your Keychain.
#   SPARKLE_DOWNLOAD_BASE points the feed at another host (testing an update from a local server). With no key there is no feed, and this build is never offered as an update.
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
