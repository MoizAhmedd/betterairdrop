#!/bin/bash
# Prints one Sparkle <item> for a release zip, signed with the EdDSA key in $SPARKLE_ED_KEY_FILE.
# CI uploads it to the GitHub release as appcast-item.xml; scripts/release/build-appcast.sh joins them.
#
#   scripts/release/appcast-item.sh BetterAirdrop.zip 0.3.0 42 > appcast-item.xml
set -euo pipefail
ZIP=$1; VERSION=$2; BUILD=$3
REPO=${GITHUB_REPOSITORY:-MoizAhmedd/betterairdrop}
SIGN_UPDATE=${SIGN_UPDATE:-.build/artifacts/sparkle/Sparkle/bin/sign_update}
ATTRS=$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" "$ZIP")   # sparkle:edSignature="…" length="…"
case "$ATTRS" in *edSignature=*length=*) ;; *) echo "sign_update gave no signature" >&2; exit 1 ;; esac
CHANNEL=""
case "$VERSION" in *-*) CHANNEL="      <sparkle:channel>beta</sparkle:channel>" ;; esac   # pre-releases: opt-in only
cat <<ITEM
    <item>
      <title>BetterAirdrop $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
${CHANNEL:+$CHANNEL
}      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/BetterAirdrop.zip" type="application/octet-stream" $ATTRS/>
    </item>
ITEM
