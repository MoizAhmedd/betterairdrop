#!/bin/sh
# BetterAirdrop installer: puts BetterAirdrop.app in ~/Applications and opens it.
#
#   curl -fsSL https://moizahmedd.github.io/betterairdrop/install | sh
#
# No sudo. Checks the zip's SHA-256 against the release's SHA256SUMS before installing.
# BETTERAIRDROP_VERSION=0.3.0 installs a specific release (pre-releases too) instead of the latest.
set -eu

REPO="MoizAhmedd/betterairdrop"
if [ -n "${BETTERAIRDROP_VERSION:-}" ]; then
  BASE="https://github.com/$REPO/releases/download/v${BETTERAIRDROP_VERSION#v}"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi
DEST="$HOME/Applications"

[ "$(uname)" = Darwin ] || { echo "BetterAirdrop is for macOS."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || { echo "BetterAirdrop needs macOS 13 or later."; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading BetterAirdrop…"
curl -fsSL "$BASE/BetterAirdrop.zip" -o "$tmp/BetterAirdrop.zip"
curl -fsSL "$BASE/SHA256SUMS" -o "$tmp/SHA256SUMS"
(cd "$tmp" && grep ' BetterAirdrop.zip$' SHA256SUMS | shasum -a 256 -c -) >/dev/null \
  || { echo "Checksum mismatch; nothing was installed."; exit 1; }

mkdir -p "$DEST"
osascript -e 'quit app id "dev.betterairdrop.app"' >/dev/null 2>&1 || true
rm -rf "$DEST/BetterAirdrop.app"
ditto -x -k "$tmp/BetterAirdrop.zip" "$DEST"
# curl doesn't set the quarantine flag; clear it anyway in case a proxy or tool did.
xattr -dr com.apple.quarantine "$DEST/BetterAirdrop.app" 2>/dev/null || true
echo "Installed $DEST/BetterAirdrop.app"
open "$DEST/BetterAirdrop.app"
echo "BetterAirdrop is in your menu bar."
