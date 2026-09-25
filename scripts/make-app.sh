#!/bin/bash
# Builds BetterAirdrop.app with SwiftPM (Xcode or the Command Line Tools; no .xcodeproj).
#
#   scripts/make-app.sh                      release build for this Mac's architecture, ad-hoc signed,
#                                            → .build/app/BetterAirdrop.app
#   scripts/make-app.sh --debug              debug build
#   scripts/make-app.sh --universal          arm64 + x86_64 (needs full Xcode)
#   scripts/make-app.sh --sign "IDENTITY"    sign with a certificate (SHA-1 or name) instead of ad-hoc
#   scripts/make-app.sh --out DIR            put the app in DIR
#   scripts/make-app.sh --version 0.3.0 --build 42
#
# Sparkle's feed and key come from SPARKLE_FEED_URL / SPARKLE_PUBLIC_KEY (empty = updater off).
set -euo pipefail
cd "$(dirname "$0")/.."

CONF=release; UNIVERSAL=0; IDENTITY="-"; OUT=".build/app"; VERSION="0.3.0-dev"; BUILD="1"
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONF=debug ;;
    --universal) UNIVERSAL=1 ;;
    --sign) IDENTITY="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --version) VERSION="$2"; shift ;;
    --build) BUILD="$2"; shift ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
  shift
done

ARGS=(-c "$CONF")
[ $UNIVERSAL = 1 ] && ARGS+=(--arch arm64 --arch x86_64)
echo "==> swift build ${ARGS[*]}"
swift build "${ARGS[@]}" --product BetterAirdropApp
swift build "${ARGS[@]}" --product betterairdrop
BIN=$(swift build "${ARGS[@]}" --show-bin-path)

APP="$OUT/BetterAirdrop.app"
C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Helpers" "$C/Frameworks" "$C/Resources"

# (Product is BetterAirdropApp: "BetterAirdrop" would collide with "betterairdrop" on a case-insensitive disk.)
cp "$BIN/BetterAirdropApp" "$C/MacOS/BetterAirdrop"
cp "$BIN/betterairdrop" "$C/Helpers/betterairdrop"
ditto "$BIN/Sparkle.framework" "$C/Frameworks/Sparkle.framework"
cp Sources/BetterAirdropCore/Resources/cities.bin "$C/Resources/cities.bin"
# The executable looks for Sparkle next to itself (SwiftPM's rpath); in a bundle it's in Frameworks.
otool -l "$C/MacOS/BetterAirdrop" | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" "$C/MacOS/BetterAirdrop" 2>/dev/null
# install_name_tool invalidates the linker's signature; re-sign so the binary can run below.
codesign --force -s - "$C/MacOS/BetterAirdrop" 2>/dev/null

sed -e "s|__VERSION__|$VERSION|" -e "s|__BUILD__|$BUILD|" \
    -e "s|__SU_FEED_URL__|${SPARKLE_FEED_URL:-}|" -e "s|__SU_PUBLIC_KEY__|${SPARKLE_PUBLIC_KEY:-}|" \
    Resources/App/Info.plist > "$C/Info.plist"
plutil -lint "$C/Info.plist" >/dev/null

# The icon is drawn by the app itself (Sources/BetterAirdropApp/Art.swift).
ICONSET=$(mktemp -d)/AppIcon.iconset
"$C/MacOS/BetterAirdrop" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Sign inside-out. No hardened runtime (so Sparkle's framework loads without a Team ID) and no
# timestamp (self-signed and ad-hoc identities have no timestamp server).
echo "==> codesign ($([ "$IDENTITY" = - ] && echo ad-hoc || echo "$IDENTITY"))"
SIGN=(codesign --force --timestamp=none -s "$IDENTITY")
FW="$C/Frameworks/Sparkle.framework/Versions/Current"
for x in "$FW"/XPCServices/*.xpc "$FW/Autoupdate" "$FW/Updater.app"; do [ -e "$x" ] && "${SIGN[@]}" "$x"; done
"${SIGN[@]}" "$C/Frameworks/Sparkle.framework"
"${SIGN[@]}" -i dev.betterairdrop.cli "$C/Helpers/betterairdrop"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> $APP"
codesign -d -r- "$APP" 2>&1 | grep designated
