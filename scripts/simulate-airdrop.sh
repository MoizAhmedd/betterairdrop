#!/bin/bash
# Drops stock macOS landscape photos into a folder the way AirDrop does (named IMG_####.HEIC, with a
# `com.apple.quarantine` xattr whose agent is sharingd), to try the app without an iPhone.
#
#   scripts/simulate-airdrop.sh DIR [COUNT]      default COUNT = 3
#
# Point the app at DIR first (watch.folder in a test config), never at your real Downloads.
set -euo pipefail
DIR="${1:?usage: $0 DIR [COUNT]}"; N="${2:-3}"
SRC="/System/Library/Desktop Pictures/.thumbnails"
mkdir -p "$DIR"
i=0
for f in "$SRC"/*.heic; do
  [ $i -ge "$N" ] && break
  name=$(printf 'IMG_%04d.HEIC' $((5300 + RANDOM % 600)))
  cp "$f" "$DIR/.$name.part"
  xattr -w com.apple.quarantine "$(printf '0081;%08x;sharingd;%s' "$(date +%s)" "$(uuidgen)")" "$DIR/.$name.part"
  mv "$DIR/.$name.part" "$DIR/$name"     # appears in one step, like a finished AirDrop
  echo "dropped $name"
  i=$((i + 1)); sleep 0.2
done
