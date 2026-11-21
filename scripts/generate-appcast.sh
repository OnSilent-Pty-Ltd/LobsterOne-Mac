#!/bin/bash
set -euo pipefail

MARKETING_VERSION="${1:?Usage: generate-appcast.sh <marketing-version> <build-number> <artifact-version> <dmg-size> <ed-signature> <minimum-autoupdate-build>}"
BUILD_NUMBER="${2:?Usage: generate-appcast.sh <marketing-version> <build-number> <artifact-version> <dmg-size> <ed-signature> <minimum-autoupdate-build>}"
ARTIFACT_VERSION="${3:?Usage: generate-appcast.sh <marketing-version> <build-number> <artifact-version> <dmg-size> <ed-signature> <minimum-autoupdate-build>}"
DMG_SIZE="${4:?Usage: generate-appcast.sh <marketing-version> <build-number> <artifact-version> <dmg-size> <ed-signature> <minimum-autoupdate-build>}"
ED_SIGNATURE="${5:?Usage: generate-appcast.sh <marketing-version> <build-number> <artifact-version> <dmg-size> <ed-signature> <minimum-autoupdate-build>}"
MIN_AUTOUPDATE_BUILD="${6:?Usage: generate-appcast.sh <marketing-version> <build-number> <artifact-version> <dmg-size> <ed-signature> <minimum-autoupdate-build>}"
PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S %z')
DMG_URL="https://releases.lobsterone.ai/mac/LobsterOne-${ARTIFACT_VERSION}.dmg"

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>LobsterOne Updates</title>
    <link>https://releases.lobsterone.ai/mac/appcast.xml</link>
    <language>en</language>
    <item>
      <title>Version ${MARKETING_VERSION} (${BUILD_NUMBER})</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:minimumAutoupdateVersion>${MIN_AUTOUPDATE_BUILD}</sparkle:minimumAutoupdateVersion>
      <enclosure
        url="${DMG_URL}"
        length="${DMG_SIZE}"
        type="application/octet-stream"
        sparkle:version="${BUILD_NUMBER}"
        sparkle:shortVersionString="${MARKETING_VERSION}"
        sparkle:edSignature="${ED_SIGNATURE}" />
    </item>
  </channel>
</rss>
EOF
