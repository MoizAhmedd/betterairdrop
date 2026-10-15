#!/bin/sh
# BetterAirdrop installer: puts BetterAirdrop.app in ~/Applications and opens it.
#
#   curl -fsSL https://moizahmedd.github.io/betterairdrop/install | sh
#
# Scripted (for AI agents and dotfiles): other flags go to `betterairdrop setup`, which runs before
# the app opens, so the app only shows macOS's permission prompts. See docs/install-for-agents.md.
#
#   curl -fsSL https://moizahmedd.github.io/betterairdrop/install | sh -s -- --yes --engine vision
#
# No sudo. Checks the zip's SHA-256 against the release's SHA256SUMS before installing.
set -eu

usage() {
  cat <<'USAGE'
Installs BetterAirdrop.app in ~/Applications, links `betterairdrop` into ~/.local/bin, and opens it.

  curl -fsSL https://moizahmedd.github.io/betterairdrop/install | sh -s -- [flags]

Installer flags:
  --version X        a specific release, pre-releases too (or BETTERAIRDROP_VERSION=X)
  --no-open          don't open the app
  --no-cli           don't link the betterairdrop command
Any other flag goes to `betterairdrop setup` (passing flags here counts as --yes):
  --engine auto|claude|vision|apple   --api-key-env VAR   --[no-]launch-at-login   --[no-]notify
USAGE
}

REPO="MoizAhmedd/betterairdrop"
VERSION="${BETTERAIRDROP_VERSION:-}"
OPEN=1; LINK_CLI=1

# Keep the installer's own flags; everything else is passed to `betterairdrop setup`.
n=$#; i=0
while [ "$i" -lt "$n" ]; do
  a=$1; shift; i=$((i + 1))
  case "$a" in
    --version) [ "$i" -lt "$n" ] || { echo "--version needs a value"; exit 2; }; VERSION=$1; shift; i=$((i + 1)) ;;
    --version=*) VERSION=${a#--version=} ;;
    --no-open) OPEN=0 ;;
    --no-cli) LINK_CLI=0 ;;
    -y|--yes) ;;   # implied: passing setup flags to the installer is the confirmation
    -h|--help) usage; exit 0 ;;
    *) set -- "$@" "$a" ;;
  esac
done

if [ -n "$VERSION" ]; then
  BASE="https://github.com/$REPO/releases/download/v${VERSION#v}"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi
DEST="$HOME/Applications"
APP="$DEST/BetterAirdrop.app"

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
# Quit a running copy first (only if there is one: a fresh install sends no Apple event).
if pgrep -x BetterAirdrop >/dev/null 2>&1; then
  osascript -e 'quit app id "dev.betterairdrop.app"' >/dev/null 2>&1 || true
  sleep 1
fi
rm -rf "$APP"
ditto -x -k "$tmp/BetterAirdrop.zip" "$DEST"
# curl doesn't set the quarantine flag; clear it anyway in case a proxy or tool did.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "Installed $APP"

CLI="$APP/Contents/Helpers/betterairdrop"
LINK="$HOME/.local/bin/betterairdrop"
if [ "$LINK_CLI" = 1 ]; then
  # Same link as Settings → Advanced → Install; never replaces something that isn't ours.
  if [ ! -e "$LINK" ] && [ ! -L "$LINK" ] || readlink "$LINK" 2>/dev/null | grep -q '\.app/Contents/Helpers/betterairdrop$'; then
    mkdir -p "$HOME/.local/bin" && ln -sfn "$CLI" "$LINK" && echo "Linked $LINK"
  fi
fi

if [ $# -gt 0 ]; then
  # When piped from curl, stdin is this script: setup mustn't read it.
  "$CLI" setup --yes --no-open "$@" </dev/null || { echo "Setup failed (the app is installed; fix the flags and run: $CLI setup …)"; exit 1; }
fi

if [ "$OPEN" = 1 ]; then
  open "$APP"
  echo "BetterAirdrop is in your menu bar."
  [ $# -gt 0 ] && echo "Check what's left with: $CLI status --json"
fi
exit 0
