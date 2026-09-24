#!/bin/bash
# M7 spike: does a free, self-signed code-signing certificate keep macOS permissions across app
# updates, the way a Developer ID would? (UX-PROPOSAL.md §3.2, docs/spikes.md §(f))
#
# It builds a toy menu-bar app (LSUIElement, no Dock icon) twice, v1 and v2 (different code, so a
# different cdhash), in three flavours:
#
#   signed  dev.betterairdrop.spike.signed  signed with a throwaway self-signed certificate
#   adhoc   dev.betterairdrop.spike.adhoc   ad-hoc signed (codesign -s -), for contrast
#   macl    dev.betterairdrop.spike.macl    ad-hoc, but v1 gets Downloads through an Open panel
#                                           (user intent, the com.apple.macl route) instead of the prompt
#
# Each launch lists ~/Downloads (it only COUNTS entries; no names are read, printed or changed),
# writes or reads a Keychain item, checks SMAppService.mainApp and posts a notification with a
# thumbnail and two action buttons. Every result is appended to results.log.
#
#   scripts/spike-signing.sh prepare            build + sign all six apps and compare their designated
#                                               requirements (no prompts, safe to run any time)
#   scripts/spike-signing.sh walk               the guided run: prepare, then v1 → v2 for each flavour,
#                                               telling you what to click at each step
#   scripts/spike-signing.sh run FLAVOUR v1|v2  one step on its own (installs that build in place, launches it)
#   scripts/spike-signing.sh results            print the log and the pass/fail table
#   scripts/spike-signing.sh cleanup            unregister login items, delete the Keychain items, reset
#                                               TCC for the spike bundle IDs, remove every file
#
# The signing identity lives only in a temporary keychain inside the work folder. It is put on the
# keychain search list for the few seconds codesign needs it, the original list is restored, and the
# keychain and private key are deleted before `prepare` exits. The login keychain is never modified
# by the signing step. (The Keychain *probe* in the check does write one item to the login keychain;
# that item is the thing being tested, and `cleanup` deletes it.)
set -euo pipefail

WORK="${BETTERAIRDROP_SPIKE_DIR:-$HOME/Library/Application Support/betterairdrop-spike-signing}"
LOG="$WORK/results.log"
BUILD="$WORK/build"
APPS="$WORK/apps"
TMPKC="$WORK/spike-signing.keychain-db"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
FLAVOURS=(signed adhoc macl)
NOTIFY_WAIT="${NOTIFY_WAIT:-40}"

[ "$(uname)" = Darwin ] || { echo "macOS only"; exit 1; }

say() { printf '\n==> %s\n' "$*"; }
bundle_id() { echo "dev.betterairdrop.spike.$1"; }
app_name() {
  case "$1" in
    signed) echo "BetterAirdrop Spike Signed" ;;
    adhoc) echo "BetterAirdrop Spike Adhoc" ;;
    macl) echo "BetterAirdrop Spike Panel" ;;
    *) echo "unknown flavour: $1 (signed, adhoc or macl)" >&2; exit 2 ;;
  esac
}

write_source() {  # $1 = file
  cat > "$1" <<'SWIFT'
import AppKit
import Security
import ServiceManagement
import UserNotifications

#if V2
let buildVersion = "v2"
#else
let buildVersion = "v1"
#endif

let argv = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
let logPath = arg("--log") ?? "/dev/stdout"
let flavour = arg("--flavor") ?? "?"
let mode = arg("--mode") ?? "check"
let notifyWait = Double(arg("--notify-wait") ?? "40") ?? 40
let useOpenPanel = argv.contains("--open-panel")
let service = "dev.betterairdrop.spike.\(flavour)"

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(flavour) \(buildVersion) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
    else { FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8)) }
}

func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

/// Counts ~/Downloads entries. A call that blocks for more than a second almost always means
/// macOS showed a permission prompt while it waited.
func listDownloads(_ url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) -> String {
    let t = Date()
    do {
        let n = try FileManager.default.contentsOfDirectory(atPath: url.path).count
        let d = ms(since: t)
        return "downloads=OK entries=\(n) ms=\(d)\(d > 1000 ? " (blocked: a prompt was probably shown)" : "")"
    } catch {
        let e = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return "downloads=FAIL \(e.map { "errno=\($0.code)" } ?? "\(error)") ms=\(ms(since: t))"
    }
}

func keychainQuery() -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "probe"]
}

func keychainWrite() -> String {
    SecItemDelete(keychainQuery() as CFDictionary)
    var add = keychainQuery()
    add[kSecValueData] = Data("written by \(buildVersion)".utf8)
    add[kSecAttrLabel] = "BetterAirdrop signing spike (safe to delete)"
    let st = SecItemAdd(add as CFDictionary, nil)
    return "keychain-write=\(st == errSecSuccess ? "OK" : "FAIL status=\(st)")"
}

func keychainRead() -> String {
    var q = keychainQuery()
    q[kSecReturnData] = true
    q[kSecMatchLimit] = kSecMatchLimitOne
    var out: CFTypeRef?
    let t = Date()
    let st = SecItemCopyMatching(q as CFDictionary, &out)
    let d = ms(since: t)
    guard st == errSecSuccess, let data = out as? Data else { return "keychain-read=FAIL status=\(st) ms=\(d)" }
    return "keychain-read=OK value=\"\(String(decoding: data, as: UTF8.self))\" ms=\(d)\(d > 1000 ? " (blocked: a keychain prompt was probably shown)" : "")"
}

@available(macOS 13, *)
func loginItem(register: Bool) -> String {
    var s = ""
    if register {
        do { try SMAppService.mainApp.register(); s = "login-register=OK " }
        catch { s = "login-register=FAIL \((error as NSError).code) " }
    }
    let status: String = switch SMAppService.mainApp.status {
    case .enabled: "enabled"
    case .notRegistered: "notRegistered"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown"
    }
    return s + "login-status=\(status)"
}

func thumbnailFile() -> URL? {
    let img = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in
        NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.9, alpha: 1).setFill(); r.fill()
        NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 36, dy: 36)).fill()
        return true
    }
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spike-thumb-\(UUID().uuidString).png")
    return (try? png.write(to: url)) != nil ? url : nil
}

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var actionSeen: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        Task { @MainActor in
            if mode == "cleanup" { await cleanup() } else { await check() }
            NSApp.terminate(nil)
        }
    }

    @MainActor func check() async {
        log("launch pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "?")")
        // 1. Downloads
        if useOpenPanel && buildVersion == "v1" {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.message = "Choose your Downloads folder, then click Grant Access. (Signing spike: it only counts the files.)"
            panel.prompt = "Grant Access"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            if panel.runModal() == .OK, let url = panel.url {
                log("open-panel chose=\(url.lastPathComponent == "Downloads" ? "Downloads" : "another folder") " + listDownloads(url))
            } else {
                log("open-panel cancelled")
            }
        } else {
            log(listDownloads())
        }
        // 2. Keychain: v1 writes, v2 reads what v1 wrote.
        log(buildVersion == "v1" ? keychainWrite() + " then " + keychainRead() : keychainRead())
        // 3. Login item (registered by v1; v2 only reports the status).
        if #available(macOS 13, *) { log(loginItem(register: buildVersion == "v1")) }
        // 4. Notification with a thumbnail and two actions.
        await notify()
    }

    @MainActor func notify() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        let settings = await center.notificationSettings()
        log("notify-auth=\(granted ? "granted" : "denied") status=\(settings.authorizationStatus.rawValue)")
        guard granted else { return }
        let undo = UNNotificationAction(identifier: "undo", title: "Undo")
        let reveal = UNNotificationAction(identifier: "reveal", title: "Show in Finder")
        center.setNotificationCategories([UNNotificationCategory(identifier: "spike.batch", actions: [undo, reveal], intentIdentifiers: [])])
        let content = UNMutableNotificationContent()
        content.title = "Spike \(flavour) \(buildVersion): click Undo"
        content.body = "Hover this banner and click Undo (or Show in Finder). Waiting \(Int(notifyWait)) s."
        content.categoryIdentifier = "spike.batch"
        var attached = "no"
        if let thumb = thumbnailFile(), let a = try? UNNotificationAttachment(identifier: "thumb", url: thumb) {
            content.attachments = [a]; attached = "yes"
        }
        do {
            try await center.add(UNNotificationRequest(identifier: "spike-\(flavour)-\(buildVersion)", content: content, trigger: nil))
            log("notify-post=OK attachment=\(attached)")
        } catch {
            log("notify-post=FAIL \(error)")
            return
        }
        let deadline = Date().addingTimeInterval(notifyWait)
        while actionSeen == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
        log("notify-action=\(actionSeen ?? "none (no click within \(Int(notifyWait)) s)")")
    }

    @MainActor func cleanup() async {
        if #available(macOS 13, *) {
            do { try await SMAppService.mainApp.unregister(); log("cleanup login-unregister=OK") }
            catch { log("cleanup login-unregister=\((error as NSError).code) (fine if it was never registered)") }
        }
        let st = SecItemDelete(keychainQuery() as CFDictionary)
        log("cleanup keychain-delete=\(st == errSecSuccess ? "OK" : st == errSecItemNotFound ? "none" : "status \(st)")")
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        await MainActor.run { actionSeen = r.actionIdentifier == UNNotificationDefaultActionIdentifier ? "banner-click" : r.actionIdentifier }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
SWIFT
}

write_plist() {  # $1 = bundle dir, $2 = flavour, $3 = version
  local id name; id=$(bundle_id "$2"); name=$(app_name "$2")
  cat > "$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.${3#v}</string>
  <key>CFBundleVersion</key><string>${3#v}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSDownloadsFolderUsageDescription</key><string>The signing spike counts the files in Downloads to test whether the permission survives an update.</string>
</dict></plist>
EOF
}

# Creates the throwaway identity in a temporary keychain and sets SHA to its SHA-1. The private key
# only ever exists inside $WORK and is deleted by drop_identity.
ORIG_KEYCHAINS=()
make_identity() {
  local d="$WORK/identity"; mkdir -p "$d"; chmod 700 "$d"
  local ossl_legacy=()
  if openssl version | grep -q '^OpenSSL 3'; then ossl_legacy=(-legacy); fi
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/key.pem" -out "$d/cert.pem" -days 30 \
    -subj "/CN=BetterAirdrop signing spike (throwaway)" \
    -addext "extendedKeyUsage=critical,codeSigning" -addext "keyUsage=critical,digitalSignature" \
    -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1
  local pass; pass=$(openssl rand -hex 16)
  openssl pkcs12 -export ${ossl_legacy[@]+"${ossl_legacy[@]}"} -inkey "$d/key.pem" -in "$d/cert.pem" -out "$d/id.p12" \
    -passout "pass:$pass" -name "BetterAirdrop signing spike" >/dev/null 2>&1
  rm -f "$d/key.pem"
  security delete-keychain "$TMPKC" >/dev/null 2>&1 || true
  security create-keychain -p "$pass" "$TMPKC"
  security set-keychain-settings "$TMPKC"            # no auto-lock
  security unlock-keychain -p "$pass" "$TMPKC"
  security import "$d/id.p12" -k "$TMPKC" -P "$pass" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$pass" "$TMPKC" >/dev/null 2>&1
  rm -f "$d/id.p12"
  # codesign only finds identities in keychains on the search list. Add ours in front, restore later.
  while IFS= read -r k; do k="${k#"${k%%[![:space:]]*}"}"; k="${k#\"}"; k="${k%\"}"; [ -n "$k" ] && ORIG_KEYCHAINS+=("$k"); done \
    < <(security list-keychains -d user)
  security list-keychains -d user -s "$TMPKC" "${ORIG_KEYCHAINS[@]}"
  SHA=$(openssl x509 -in "$d/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
}

drop_identity() {
  if [ ${#ORIG_KEYCHAINS[@]} -gt 0 ]; then security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}"; ORIG_KEYCHAINS=(); fi
  security delete-keychain "$TMPKC" >/dev/null 2>&1 || true
  rm -rf "$WORK/identity/key.pem" "$WORK/identity/id.p12"
}

prepare() {
  mkdir -p "$WORK" "$BUILD"
  local src="$WORK/src"; mkdir -p "$src"; write_source "$src/main.swift"
  trap drop_identity EXIT
  say "Creating a throwaway self-signed code-signing identity in a temporary keychain"
  make_identity; local sha=$SHA
  echo "certificate SHA-1: $sha (expires in 30 days; the private key is deleted in a moment)"
  for f in "${FLAVOURS[@]}"; do
    for v in v1 v2; do
      local name dir; name=$(app_name "$f"); dir="$BUILD/$f/$v/$name.app"
      rm -rf "$dir"; mkdir -p "$dir/Contents/MacOS"
      write_plist "$dir" "$f" "$v"
      local flags=(); [ $v = v2 ] && flags=(-D V2)
      swiftc -O ${flags[@]+"${flags[@]}"} "$src/main.swift" -o "$dir/Contents/MacOS/spike" 2>&1 | grep -v '^$' || true
      local id; id=$(bundle_id "$f")
      if [ "$f" = signed ]; then
        codesign --force --timestamp=none -s "$sha" -i "$id" \
          -r="designated => identifier \"$id\" and certificate leaf = H\"$sha\"" "$dir"
      else
        codesign --force -s - -i "$id" "$dir"
      fi
    done
  done
  drop_identity; trap - EXIT
  security list-keychains -d user | grep -q "spike-signing" && { echo "search list not restored!"; exit 1; }
  echo "temporary keychain deleted; search list restored:"; security list-keychains -d user
  compare | tee "$WORK/prepare.txt"
}

# Ad-hoc code has only an implicit requirement, printed as "# designated => cdhash H\"…\"".
dr() { codesign -d -r- "$1" 2>&1 | sed -n 's/^\(# \)\{0,1\}designated => //p'; }
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

compare() {
  say "Designated requirements (what TCC and the Keychain remember about an app)"
  local pass=1
  for f in "${FLAVOURS[@]}"; do
    local name a b; name=$(app_name "$f")
    a="$BUILD/$f/v1/$name.app"; b="$BUILD/$f/v2/$name.app"
    codesign --verify --strict "$a" && codesign --verify --strict "$b" || { echo "$f: signature invalid"; pass=0; }
    local dr1 dr2 h1 h2; dr1=$(dr "$a"); dr2=$(dr "$b"); h1=$(cdhash "$a"); h2=$(cdhash "$b")
    echo "[$f] v1 cdhash $h1"
    echo "[$f] v2 cdhash $h2"
    echo "[$f] v1 DR: $dr1"
    echo "[$f] v2 DR: $dr2"
    local same=no; [ "$dr1" = "$dr2" ] && same=yes
    local crossed=no  # does v2's code satisfy v1's requirement? (what TCC checks after an update)
    codesign --verify -R="$dr1" "$b" >/dev/null 2>&1 && crossed=yes
    echo "[$f] cdhash differs: $([ "$h1" != "$h2" ] && echo yes || echo NO) · DR identical: $same · v2 satisfies v1's DR: $crossed"
    case "$f" in
      signed) [ $same = yes ] && [ $crossed = yes ] || pass=0 ;;
      *) [ $crossed = no ] || pass=0 ;;
    esac
  done
  echo
  if [ $pass = 1 ]; then
    echo "static check PASS: the signed v2 satisfies v1's requirement; ad-hoc v2 does not."
  else
    echo "static check FAIL: see above."
  fi
}

run_step() {  # $1 flavour, $2 v1|v2
  local f=$1 v=$2 name; name=$(app_name "$f")
  local built="$BUILD/$f/$v/$name.app" dest="$APPS/$name.app"
  [ -d "$built" ] || { echo "not built yet: run '$0 prepare' first"; exit 1; }
  mkdir -p "$APPS"
  # Replace the installed app in place, as an updater would (same path, new code).
  rm -rf "$dest.new"; ditto "$built" "$dest.new"; rm -rf "$dest"; mv "$dest.new" "$dest"
  "$LSREGISTER" -f "$dest" >/dev/null 2>&1 || true
  local extra=(); [ "$f" = macl ] && extra=(--open-panel)
  say "Launching $name ($v). It quits by itself after about $NOTIFY_WAIT s."
  open -W -n "$dest" --args --flavor "$f" --log "$LOG" --notify-wait "$NOTIFY_WAIT" ${extra[@]+"${extra[@]}"}
  grep " $f $v " "$LOG" | tail -6 | sed 's/^/    /'
}

pause() { printf '\n%s\n[press Return to continue] ' "$*"; read -r _; }

walk() {
  prepare
  cat <<EOF

This takes about 10 minutes. Each launch shows a notification: hover it and click **Undo**.
Nothing in Downloads is renamed, moved or read; the spike only counts the entries.
EOF
  pause "STEP 1/6  signed v1. Expect: a prompt '$(app_name signed) would like to access files in your Downloads folder' → click Allow. Then a notifications prompt → Allow. Maybe a 'Background item added' notice."
  run_step signed v1
  pause "STEP 2/6  signed v2 (swapped in place). Expect: NO Downloads prompt and NO keychain prompt. If one appears, note it and click Allow / Always Allow."
  run_step signed v2
  pause "STEP 3/6  adhoc v1. Expect: the Downloads prompt → Allow; notifications prompt → Allow."
  run_step adhoc v1
  pause "STEP 4/6  adhoc v2. Expected to FAIL: a new Downloads prompt (click Don't Allow) and/or a keychain prompt (click Deny). Note what you saw."
  run_step adhoc v2
  pause "STEP 5/6  panel v1. Expect: an Open panel preset to Downloads → click 'Grant Access' (no TCC prompt should appear)."
  run_step macl v1
  pause "STEP 6/6  panel v2. Does the Open-panel grant survive an ad-hoc update? Note any prompt (click Don't Allow)."
  run_step macl v2
  results
  cat <<EOF

Done. Copy everything from "Designated requirements" down into docs/spikes.md §(f) (or send it
to the maintainer), then run:  $0 cleanup
EOF
}

field() { echo "$1" | grep -o "$2" | tail -1 | cut -d= -f2 || true; }

results() {
  [ -f "$WORK/prepare.txt" ] && cat "$WORK/prepare.txt"
  say "results.log"
  [ -f "$LOG" ] && sed 's/^/    /' "$LOG" || echo "    (no runs yet)"
  say "Summary (v2 after swapping v1 out)"
  printf '%-8s %-14s %-14s %-16s %-14s\n' flavour downloads keychain login-item notification
  for f in "${FLAVOURS[@]}"; do
    local l; l=$(grep " $f v2 " "$LOG" 2>/dev/null || true)
    local d k s n
    d=$(field "$l" 'downloads=[A-Z]*'); echo "$l" | grep -q 'downloads=OK.*blocked' && d="$d(prompt)"
    k=$(field "$l" 'keychain-read=[A-Z]*'); echo "$l" | grep -q 'keychain-read=OK.*blocked' && k="$k(prompt)"
    s=$(field "$l" 'login-status=[A-Za-z]*')
    n=$(field "$l" 'notify-action=[a-z-]*')
    printf '%-8s %-14s %-14s %-16s %-14s\n' "$f" "${d:--}" "${k:--}" "${s:--}" "${n:--}"
  done
  cat <<'EOF'

PASS = signed: downloads OK and keychain OK with no (prompt); adhoc: FAIL or (prompt).
EOF
}

cleanup() {
  say "Cleaning up"
  for f in "${FLAVOURS[@]}"; do
    local name dest id; name=$(app_name "$f"); dest="$APPS/$name.app"; id=$(bundle_id "$f")
    if [ -d "$dest" ]; then
      "$dest/Contents/MacOS/spike" --mode cleanup --flavor "$f" --log "$LOG" >/dev/null 2>&1 || true
    fi
    # tccutil resolves the bundle ID through Launch Services, so reset before unregistering.
    tccutil reset All "$id" >/dev/null 2>&1 && echo "tccutil reset All $id" || echo "tccutil: nothing to reset for $id"
    [ -d "$dest" ] && { "$LSREGISTER" -u "$dest" >/dev/null 2>&1 || true; }
    for v in v1 v2; do "$LSREGISTER" -u "$BUILD/$f/$v/$name.app" >/dev/null 2>&1 || true; done
  done
  drop_identity
  [ -f "$LOG" ] && cp "$LOG" "/tmp/betterairdrop-spike-signing-results.log" && echo "log saved to /tmp/betterairdrop-spike-signing-results.log"
  [ -f "$WORK/prepare.txt" ] && cp "$WORK/prepare.txt" "/tmp/betterairdrop-spike-signing-prepare.txt"
  rm -rf "$WORK"
  echo "Removed $WORK."
  echo "Left for you to check by hand: System Settings → Notifications (remove the 'BetterAirdrop Spike …' entries"
  echo "if they are still listed) and General → Login Items (nothing named 'BetterAirdrop Spike' should remain)."
}

case "${1:-}" in
  prepare) prepare ;;
  walk) walk ;;
  run) [ $# -eq 3 ] || { echo "usage: $0 run signed|adhoc|macl v1|v2"; exit 2; }; app_name "$2" >/dev/null; run_step "$2" "$3" ;;
  results) results ;;
  cleanup) cleanup ;;
  compare) compare ;;
  *) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
