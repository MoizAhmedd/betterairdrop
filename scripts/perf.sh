#!/bin/bash
# Measures arrival → rename through the real watcher (release build), on COPIES of photos you
# choose, in a throwaway folder with its own state. Your Downloads and history are never touched.
#
#   scripts/perf.sh single PHOTO...       each photo arrives alone; one timing per photo
#   scripts/perf.sh batch PHOTO...        all arrive 0.2 s apart as one burst; one timing for the lot
#
#   BACKEND=vision scripts/perf.sh ...    force a backend (default: auto = Claude if a credential resolves)
#   KEEP=1                                keep the throwaway folder (the names) for a look afterwards
#
# Prints the wall time from the file appearing (like a finished AirDrop) to the renamed file
# appearing, then the watcher's per-stage timings. Results for docs/perf.md; photos stay local.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:?usage: $0 single|batch PHOTO...}"; shift
[ $# -gt 0 ] || { echo "no photos given" >&2; exit 2; }
BACKEND="${BACKEND:-auto}"

swift build -c release --product betterairdrop 2>&1 | grep -E "error|Compiling|Build complete" | tail -1 >&2 || true
BIN="$(swift build -c release --show-bin-path)/betterairdrop"

W=$(mktemp -d /tmp/betterairdrop-perf.XXXXXX)
mkdir -p "$W/Drop" "$W/state"
printf 'backend = "%s"\n\n[watch]\nfolder = "%s/Drop"\nnotify = false\n' "$BACKEND" "$W" > "$W/config.toml"
LOG="$W/watch.log"
BETTERAIRDROP_HOME="$W/state" "$BIN" watch --foreground --no-notify --config "$W/config.toml" --dir "$W/Drop" > "$LOG" 2>&1 &
WPID=$!
cleanup() { kill -INT $WPID 2>/dev/null; sleep 0.3; kill $WPID 2>/dev/null || true; [ -n "${KEEP:-}" ] && echo "kept $W" >&2 || rm -rf "$W"; }
trap cleanup EXIT
until grep -q "watching" "$LOG" 2>/dev/null; do sleep 0.05; done
sleep 1

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
n=0
drop() {   # drop SRC N → prints the name it arrived as
  local ext="${1##*.}" name
  name=$(printf 'IMG_%04d.%s' $((7000 + $2)) "$ext")
  cp "$1" "$W/Drop/.$name.part"
  xattr -w com.apple.quarantine "$(printf '0081;%08x;sharingd;%s' "$(date +%s)" "$(uuidgen)")" "$W/Drop/.$name.part"
  mv "$W/Drop/.$name.part" "$W/Drop/$name"   # appears in one step, like a finished AirDrop
  echo "$name"
}
wait_gone() {   # waits until every named file has been renamed away (60 s limit)
  local end=$(( $(date +%s) + 60 ))
  for f in "$@"; do
    while [ -e "$W/Drop/$f" ]; do
      [ "$(date +%s)" -lt $end ] || { echo "timed out waiting for $f" >&2; return 1; }
      sleep 0.01
    done
  done
}

case "$MODE" in
  single)
    for p in "$@"; do
      n=$((n + 1)); t0=$(now); name=$(drop "$p" $n); wait_gone "$name"; t1=$(now)
      printf 'single  %-10s %5.2f s\n' "${p##*.}" "$(echo "$t1 - $t0" | bc)"
      sleep 1.5
    done ;;
  batch)
    names=(); t0=$(now)
    for p in "$@"; do n=$((n + 1)); names+=("$(drop "$p" $n)"); sleep 0.2; done
    wait_gone "${names[@]}"; t1=$(now)
    printf 'batch   %d photos %5.2f s (first arrival → last rename)\n' "$#" "$(echo "$t1 - $t0" | bc)" ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
sleep 0.5
echo "--- watcher stage timings"
grep -E "^\s+(settle|quiet|credential|vision|encode|claude|convert|commit|total)" "$LOG" | sed 's/^ *//' || true
grep -E "note:|✗" "$LOG" || true
