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
  GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}" MICROSOFT_CLIENT_ID="${MICROSOFT_CLIENT_ID:-}" \
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

# Signing the update (appcast.xml) and the checksums live in scripts/sign-update.sh, so CI can give the Sparkle private key to that step alone.
# CI sets SKIP_UPDATE_SIGNING=1 here and runs it as a separate step; everywhere else it just follows.
[ -n "${SKIP_UPDATE_SIGNING:-}" ] || exec scripts/sign-update.sh "$VERSION"
