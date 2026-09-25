#!/bin/bash
# Prints appcast.xml from the appcast-item.xml asset of every published release, newest first.
# Stateless, so every Pages deploy (a site edit or a release) rebuilds the same feed. Needs `gh`.
set -euo pipefail
REPO=${GITHUB_REPOSITORY:-MoizAhmedd/betterairdrop}
cat <<'HEAD'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>BetterAirdrop</title>
    <link>https://moizahmedd.github.io/betterairdrop/appcast.xml</link>
HEAD
gh release list -R "$REPO" --limit 100 --exclude-drafts --json tagName,createdAt \
  --jq 'sort_by(.createdAt) | reverse | .[].tagName' |
while read -r tag; do
  gh release download "$tag" -R "$REPO" -p appcast-item.xml -O - 2>/dev/null || true
done
cat <<'TAIL'
  </channel>
</rss>
TAIL
