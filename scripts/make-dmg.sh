#!/bin/bash
# Builds dex-notch.app (universal, ad-hoc signed) and packages it as a .dmg and a .zip in build/dist/.
#   scripts/make-dmg.sh [version]        e.g. scripts/make-dmg.sh v0.1.0
# Ad-hoc signing means macOS shows a one-time "unidentified developer" prompt (right-click > Open). Notarizing needs a paid
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
  PRODUCT_NAME="dex-notch" MARKETING_VERSION="$NUM" CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGNING_ALLOWED=YES \
  build | tail -n 3

APP="$DD/Build/Products/Release/dex-notch.app"
[ -d "$APP" ] || { echo "build did not produce $APP" >&2; exit 1; }

# the signature must be valid and the binary must really be universal, or the DMG is not worth shipping
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/dex-notch" | grep -q arm64 && lipo -archs "$APP/Contents/MacOS/dex-notch" | grep -q x86_64 \
  || { echo "binary is not universal: $(lipo -archs "$APP/Contents/MacOS/dex-notch")" >&2; exit 1; }

# nothing but the app itself may ship: no tooling folders, logs or data files that slipped in from a messy working tree
STRAY=$(find "$APP" \( -name ".claude-flow" -o -name ".swarm" -o -name ".superpowers" -o -name "patterns.json" -o -name "*.log" -o -name ".env*" -o -name "*.jsonl" \) | head -5)
[ -z "$STRAY" ] || { echo "refusing to package: unexpected files inside the app:" >&2; echo "$STRAY" >&2; exit 1; }
WANT="$NUM"; GOT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$GOT" = "$WANT" ] || { echo "version in the app is $GOT, expected $WANT" >&2; exit 1; }

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<TXT
dex-notch $VERSION

1. Drag dex-notch into Applications.
2. The first time, right-click it and choose Open (macOS asks once, because this build is not notarized).
   If macOS still refuses: open Terminal and run
       xattr -dr com.apple.quarantine /Applications/dex-notch.app
3. A setup window opens. Pick Claude or Codex (install one first if you have neither), choose where it may work, and press Save and start.
4. Press Option+Space.

https://github.com/Dextron04/dex-notch
TXT

hdiutil create -volname "dex-notch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/dex-notch-$VERSION.dmg" >/dev/null
ditto -c -k --keepParent "$APP" "$DIST/dex-notch-$VERSION.zip"
hdiutil verify "$DIST/dex-notch-$VERSION.dmg" >/dev/null
( cd "$DIST" && shasum -a 256 dex-notch-"$VERSION".* > SHA256SUMS.txt )

echo "built:"; ls -lh "$DIST" | awk 'NR>1{print "  " $9, $5}'
