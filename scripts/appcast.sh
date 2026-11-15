#!/bin/bash
# Prints the Sparkle appcast (the feed the app reads to find updates) for one release.
#   scripts/appcast.sh <tag> <short version> <build number> '<sparkle:edSignature="…" length="…">' [download base url]
# The app compares <build number> with its own CFBundleVersion, so it must go up with every release (the CI run number does).
set -euo pipefail
TAG="$1"; NUM="$2"; BUILD="$3"; SIG="$4"
BASE="${5:-https://github.com/Dextron04/dex-notch/releases/download/$TAG}"
DATE="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dex Notch</title>
    <link>https://github.com/Dextron04/dex-notch</link>
    <description>Dex Notch updates</description>
    <item>
      <title>Dex Notch $NUM</title>
      <link>https://github.com/Dextron04/dex-notch/releases/tag/$TAG</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$NUM</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>$DATE</pubDate>
      <enclosure url="$BASE/dex-notch-$TAG.zip" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
