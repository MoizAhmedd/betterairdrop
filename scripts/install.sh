#!/bin/sh
# BetterAirdrop installer: puts BetterAirdrop.app in ~/Applications and opens it.
#
#   curl -fsSL https://moizahmedd.github.io/betterairdrop/install.sh | sh
#
# TODO(M12): DRAFT. Not published yet, and there are no releases for it to download. It goes live
# with v0.3 once the maintainer approves the release pipeline (docs/release/README.md).
#
# No sudo. Checks the zip's SHA-256 against the release's SHA256SUMS before installing.
set -eu

REPO="MoizAhmedd/betterairdrop"
BASE="https://github.com/$REPO/releases/latest/download"
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
echo "Installed $DEST/BetterAirdrop.app"
open "$DEST/BetterAirdrop.app"
echo "BetterAirdrop is in your menu bar."
