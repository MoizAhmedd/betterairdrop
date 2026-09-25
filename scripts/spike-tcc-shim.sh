#!/bin/bash
# M0(e) spike: does a stable, ad-hoc-signed launcher .app hold the ~/Downloads (TCC) grant
# for a child binary that gets replaced, the way `brew upgrade` would replace betterairdrop?
#
#   scripts/spike-tcc-shim.sh install            build, install the LaunchAgent, run phase 1 (expect a prompt: click Allow)
#   scripts/spike-tcc-shim.sh run [label]        run the agent again (default label: 2-after-grant)
#   scripts/spike-tcc-shim.sh swap               replace the child binary with a new build, run phase 3
#   scripts/spike-tcc-shim.sh rebuild-launcher   re-sign a changed launcher (new cdhash), run phase 4
#   scripts/spike-tcc-shim.sh results            print the log
#   scripts/spike-tcc-shim.sh cleanup            remove the agent, the bundle, the log and the TCC entry
#   scripts/spike-tcc-shim.sh build              only compile + sign into $SPIKE_DIR (no launchd, no prompt)
#
# Add --dry-run anywhere to print what would happen without changing anything.
# The agent only LISTS ~/Downloads (names are counted, never printed or modified).
set -eu

LABEL=dev.betterairdrop.spike
SPIKE_DIR="${SPIKE_DIR:-$HOME/Library/Application Support/betterairdrop-spike}"
APP="$SPIKE_DIR/BetterAirdrop Spike.app"
LAUNCHER="$APP/Contents/MacOS/betterairdrop-spike"
CHILD="$SPIKE_DIR/child/betterairdrop-child"     # outside the bundle, like a Homebrew Cellar binary
LOG="$SPIKE_DIR/results.log"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

DRY=0
args=()
for a in "$@"; do [ "$a" = --dry-run ] && DRY=1 || args+=("$a"); done
set -- "${args[@]+"${args[@]}"}"

[ "$(uname)" = Darwin ] || { echo "macOS only"; exit 1; }

run() { if [ $DRY = 1 ]; then printf '[dry-run]'; printf ' %q' "$@"; echo; else "$@"; fi; }
say() { echo "==> $*"; }

build_child() {  # $1 = version stamp
  local src; src=$(mktemp -d)
  cat > "$src/child.swift" <<EOF
import Foundation
let version = "$1"
let home = FileManager.default.homeDirectoryForCurrentUser.path
let log = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
var line = "child(v\(version)) pid=\(getpid()) ppid=\(getppid()) "
do {
  let n = try FileManager.default.contentsOfDirectory(atPath: home + "/Downloads").count
  line += "LIST OK entries=\(n)"
} catch { line += "LIST FAIL errno=\((error as NSError).userInfo[NSUnderlyingErrorKey].map { "\(\$0)" } ?? "\(error)")" }
if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); h.closeFile() }
EOF
  run mkdir -p "$(dirname "$CHILD")"
  # Write to a new inode and rename over the old one, as brew does.
  run swiftc -O "$src/child.swift" -o "$CHILD.new"
  run codesign --force -s - "$CHILD.new"
  run mv -f "$CHILD.new" "$CHILD"
  rm -rf "$src"
}

build_launcher() {  # $1 = stamp (changing it changes the launcher's cdhash)
  local src; src=$(mktemp -d)
  cat > "$src/launcher.swift" <<EOF
import Foundation
let stamp = "$1"
let dir = "$SPIKE_DIR"
let log = dir + "/results.log"
func append(_ s: String) {
  if !FileManager.default.fileExists(atPath: log) { FileManager.default.createFile(atPath: log, contents: nil) }
  if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); h.closeFile() }
}
let phase = (try? String(contentsOfFile: dir + "/phase", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
let ts = ISO8601DateFormatter().string(from: Date())
append("--- phase=\(phase) at=\(ts) launcher(stamp=\(stamp)) pid=\(getpid()) ppid=\(getppid())")
let home = FileManager.default.homeDirectoryForCurrentUser.path
do {
  let n = try FileManager.default.contentsOfDirectory(atPath: home + "/Downloads").count
  append("launcher LIST OK entries=\(n)")
} catch { append("launcher LIST FAIL \((error as NSError).userInfo[NSUnderlyingErrorKey].map { "\(\$0)" } ?? "\(error)")") }
let p = Process()
p.executableURL = URL(fileURLWithPath: "$CHILD")
p.arguments = [log]
do { try p.run(); p.waitUntilExit(); append("child exit=\(p.terminationStatus)") }
catch { append("child SPAWN FAIL \(error)") }
EOF
  run mkdir -p "$APP/Contents/MacOS"
  if [ $DRY = 1 ]; then echo "[dry-run] write $APP/Contents/Info.plist (CFBundleIdentifier=$LABEL, LSUIElement)"; else
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>BetterAirdrop Spike</string>
  <key>CFBundleExecutable</key><string>betterairdrop-spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
  fi
  run swiftc -O "$src/launcher.swift" -o "$LAUNCHER"
  run codesign --force -s - -i "$LABEL" "$APP"
  rm -rf "$src"
}

write_plist() {
  if [ $DRY = 1 ]; then echo "[dry-run] write $PLIST (Program=$LAUNCHER, AssociatedBundleIdentifiers=$LABEL)"; return; fi
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$LAUNCHER</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$LABEL</string></array>
  <key>ProcessType</key><string>Background</string>
  <key>RunAtLoad</key><false/>
  <key>StandardErrorPath</key><string>$SPIKE_DIR/stderr.log</string>
</dict></plist>
EOF
}

kick() {  # $1 = phase label; runs the agent once via launchd and waits for it to log
  say "phase $1: starting the agent through launchd (answer any permission prompt)"
  if [ $DRY = 1 ]; then echo "[dry-run] echo $1 > $SPIKE_DIR/phase"; else echo "$1" > "$SPIKE_DIR/phase"; fi
  run launchctl kickstart -k "$DOMAIN/$LABEL"
  [ $DRY = 1 ] && return
  for _ in $(seq 1 120); do
    grep -q "^--- phase=$1 " "$LOG" 2>/dev/null && tail -1 "$LOG" | grep -q '^child ' && break
    sleep 1
  done
  sed -n "/^--- phase=$1 /,\$p" "$LOG"
}

cmd="${1:-help}"
case "$cmd" in
  build)
    run mkdir -p "$SPIKE_DIR"
    build_child 1; build_launcher 1
    [ $DRY = 1 ] || { codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature|CDHash'; codesign -dv "$CHILD" 2>&1 | grep -E 'Identifier|CDHash'; }
    ;;
  install)
    run mkdir -p "$SPIKE_DIR"
    build_child 1; build_launcher 1; write_plist
    run launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    run launchctl bootstrap "$DOMAIN" "$PLIST"
    kick 1-first-run
    say "If a prompt appeared and you clicked Allow, run:  $0 run"
    ;;
  run) kick "${2:-2-after-grant}" ;;
  swap)
    say "replacing the child binary (new version, new cdhash, new inode)"
    build_child 2; kick 3-child-swapped ;;
  rebuild-launcher)
    say "rebuilding the launcher with a new stamp (new cdhash, same identifier)"
    build_launcher 2; kick 4-launcher-rebuilt ;;
  results) cat "$LOG" ;;
  cleanup)
    run launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    run rm -f "$PLIST"
    [ -f "$LOG" ] && { run mkdir -p /tmp/betterairdrop-spike; run cp "$LOG" /tmp/betterairdrop-spike/results.log; say "log saved to /tmp/betterairdrop-spike/results.log"; }
    run rm -rf "$SPIKE_DIR"
    run tccutil reset SystemPolicyDownloadsFolder "$LABEL" || true
    say "removed $PLIST, $SPIKE_DIR and the Downloads permission entry for $LABEL"
    ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
