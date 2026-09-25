import AppKit
import BetterAirdropCore
import BetterAirdropKit
import SwiftUI

/// First run (UX mockup b): Welcome → folder access → naming engine → background → done.
/// Also opened at the access step alone ("Fix…") when the permission goes missing.
@MainActor
final class OnboardingState: ObservableObject {
    enum Access: Equatable { case notAsked, checking, granted, denied }
    enum Verify: Equatable { case idle, checking, ok, failed(String) }

    @Published var step = 0
    @Published var access = Access.notAsked
    @Published var engine = EngineChoice.vision
    @Published var key = ""
    @Published var verify = Verify.idle
    @Published var useKeyInsteadOfAnt = false
    @Published var replacingKey = false
    @Published var launchAtLogin = true
    @Published var notify = false
    @Published var notifyNote: String?
    @Published var backlog = false
    @Published var backlogFiles: [URL] = []

    let fixMode: Bool
    let appleReady: Bool
    var presetForSnapshot = false
    init(fixMode: Bool) {
        self.fixMode = fixMode
        if case .ready = AppleFMNamer().availability() { appleReady = true } else { appleReady = false }
        if fixMode { step = 1 }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @StateObject var s: OnboardingState
    let finish: (_ backlog: [URL]) -> Void
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// `state` lets snapshots start at a given step with given answers.
    init(model: AppModel, fixMode: Bool = false, state: OnboardingState? = nil, finish: @escaping ([URL]) -> Void) {
        self.model = model
        _s = StateObject(wrappedValue: state ?? OnboardingState(fixMode: fixMode))
        self.finish = finish
    }

    static let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch s.step {
                case 0: welcome
                case 1: accessStep
                case 2: engineStep
                case 3: backgroundStep
                default: doneStep
                }
            }
            .padding(.horizontal, 44).padding(.top, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: 620, height: 500)
        .onAppear(perform: appear)
        .onReceive(poll) { _ in if s.step == 1 && Permissions.didAsk && s.access != .granted { probe() } }
    }

    // MARK: Steps

    var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage ?? Art.appIcon()).resizable().frame(width: 96, height: 96).padding(.top, 6)
            Text("Welcome to BetterAirdrop").font(.system(size: 22, weight: .bold)).padding(.top, 10).padding(.bottom, 6)
            Text("AirDrop a photo from your iPhone and it lands in Downloads with a name you can search for, instead of IMG_4821.HEIC.")
                .font(.system(size: 13)).multilineTextAlignment(.center).frame(maxWidth: 380).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 8) {
                Feature(symbol: "sparkles", color: .blue, title: "Names from context", detail: "date, city, kind (screenshot, receipt…), text and subject")
                Feature(symbol: "arrow.left.arrow.right", color: .orange, title: "HEIC becomes JPEG", detail: "opens anywhere. The original goes to the Trash, not away.")
                Feature(symbol: "arrow.uturn.backward", color: .green, title: "Every change can be undone", detail: "from the notification or the menu bar, any time")
            }
            .frame(maxWidth: 410)
            Text("Only files AirDrop delivers are touched. Your other downloads are never renamed.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
        }
    }

    var accessStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Let BetterAirdrop see your \(model.folderName)").font(.system(size: 22, weight: .bold)).padding(.vertical, 6)
            Text("AirDrop saves photos to your \(model.folderName) folder. macOS asks you once whether BetterAirdrop may read and rename files there.")
                .font(.system(size: 13)).padding(.bottom, 10)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    FolderIcon()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(model.folderName) folder").font(.system(size: 13, weight: .medium))
                        Text(accessText).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch s.access {
                    case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
                    case .checking: ProgressView().controlSize(.small)
                    default: Button("Allow Access…", action: askAccess).buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                if s.access == .denied {
                    Divider()
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Access was turned off").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.red)
                            Text("Turn on **BetterAirdrop** under *Privacy & Security → Files & Folders → \(model.folderName)*. This window notices on its own.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Open Privacy Settings") { Permissions.openPrivacySettings() }
                            Button("Choose Folder…") { Permissions.chooseFolder(model.folder) { if $0 { granted() } } }
                                .buttonStyle(.link).font(.system(size: 12))
                        }
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.08))
                }
            }
            .groupBox()
            Text("BetterAirdrop only reads the top level of \(model.folderName), and only changes files whose macOS “downloaded by” tag says AirDrop. It never uploads your folder anywhere.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
        }
    }

    var accessText: String {
        switch s.access {
        case .notAsked: "Not allowed yet"
        case .checking: "Checking…"
        case .granted: "Access granted"
        case .denied: "Not allowed"
        }
    }

    var engineStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How should photos be named?").font(.system(size: 22, weight: .bold)).padding(.vertical, 6)
            Text("You can change this later in Settings. Whichever you pick, the date, city and kind are always worked out on this Mac.")
                .font(.system(size: 13)).padding(.bottom, 6)
            VStack(spacing: 0) {
                EngineCard(choice: .apple, selected: $s.engine, enabled: s.appleReady,
                           title: "Apple Intelligence",
                           detail: s.appleReady ? "On-device and private. Names are good, not great." : "Needs macOS 27 with Apple Intelligence on. This Mac runs macOS \(Self.osVersion).",
                           badge: ("On-device · Free", .green))
                Divider()
                EngineCard(choice: .claude, selected: $s.engine, enabled: true, title: "Claude Haiku",
                           detail: "The best names: 92% of them good in our tests, against 42% for Apple Vision. About $2 per 1,000 photos, paid to Anthropic with your own key.",
                           badge: ("Best names", .blue))
                if s.engine == .claude { keyPanel }
                Divider()
                EngineCard(choice: .vision, selected: $s.engine, enabled: true, title: "Apple Vision",
                           detail: "No setup, and nothing leaves your Mac. The names are plain, more like tags: window-brick, drinking-glass.",
                           badge: ("On-device · Free", .gray))
            }
            .groupBox()
        }
    }

    var antFound: Bool { model.credential.antLoggedIn && !s.useKeyInsteadOfAnt }

    var keyPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if antFound {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Found your Anthropic CLI login (`ant`). BetterAirdrop will use it; no key needed.").font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Use a key instead") { s.useKeyInsteadOfAnt = true }.buttonStyle(.link).font(.system(size: 12))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
            } else if model.credential.storedKey && !s.replacingKey {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("An API key is already saved.").font(.system(size: 12))
                    Spacer()
                    Button("Use a different key") { s.replacingKey = true }.buttonStyle(.link).font(.system(size: 12))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))
            } else {
                HStack(spacing: 6) {
                    SecureField("Paste your API key (sk-ant-…)", text: $s.key)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .onChange(of: s.key) { _ in if s.verify != .checking { s.verify = .idle } }
                    Button(s.verify == .checking ? "Verifying…" : "Verify", action: verifyKey)
                        .disabled(s.key.trimmingCharacters(in: .whitespaces).isEmpty || s.verify == .checking)
                }
                Group {
                    switch s.verify {
                    case .ok: Label("Key verified and saved.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let why): Label(why, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    default:
                        Text("No key yet? [Get a key from the Claude Console ↗](https://platform.claude.com/settings/keys). It takes a few minutes; Anthropic bills your account directly. The key is saved on this Mac, readable only by you.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
            }
            Text("What gets sent: a 1024 px copy of each photo with **no location or camera data**, plus the city name and any text in it. If Claude can't be reached, Apple Vision names the photo instead.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 42).padding(.trailing, 12).padding(.bottom, 12)
    }

    var backgroundStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Run quietly in the background").font(.system(size: 22, weight: .bold)).padding(.vertical, 6)
            Text("BetterAirdrop sits in the menu bar and uses no CPU until something arrives in \(model.folderName).")
                .font(.system(size: 13)).padding(.bottom, 10)
            VStack(spacing: 0) {
                ToggleRow(title: "Open BetterAirdrop when I log in", detail: "macOS will say “Background item added”. That's this.", isOn: $s.launchAtLogin)
                Divider()
                ToggleRow(title: "Tell me when photos are renamed", detail: s.notifyNote ?? "one notification per AirDrop, with an Undo button",
                          isOn: Binding(get: { s.notify }, set: setNotify))
                Divider()
                ToggleRow(title: "Also rename earlier AirDrops",
                          detail: s.backlogFiles.isEmpty ? "No earlier AirDrops found in \(model.folderName)."
                            : "\(s.backlogFiles.count) photo\(s.backlogFiles.count == 1 ? "" : "s") from AirDrop \(s.backlogFiles.count == 1 ? "is" : "are") already in \(model.folderName). You'll see the names before anything changes.",
                          isOn: $s.backlog)
                    .disabled(s.backlogFiles.isEmpty)
            }
            .groupBox()
        }
        .onAppear(perform: countBacklog)
    }

    var doneStep: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color.green.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "checkmark").font(.system(size: 28, weight: .semibold)).foregroundStyle(.green)
            }
            .padding(.top, 18)
            Text("You're set").font(.system(size: 22, weight: .bold)).padding(.top, 10).padding(.bottom, 6)
            Text("BetterAirdrop lives in your menu bar. AirDrop a photo from your iPhone to try it.")
                .font(.system(size: 13)).multilineTextAlignment(.center).frame(maxWidth: 380)
            MenuBarHint().padding(.top, 12)
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
                Text("Don't see the icon? Check **System Settings → Menu Bar**.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Summary").font(.system(size: 13, weight: .medium))
                    Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12).frame(width: 380).groupBox().padding(.top, 12)
        }
    }

    var summary: String {
        let access = s.access == .granted ? "\(model.folderName) ✓" : "\(model.folderName) not allowed yet"
        let engine = s.engine == .claude ? "Claude Haiku" : s.engine == .apple ? "Apple Intelligence" : "Apple Vision"
        return [access, engine, s.launchAtLogin ? "starts at login" : "doesn't start at login"].joined(separator: " · ")
    }

    // MARK: Footer

    var footer: some View {
        HStack {
            Button("Back") { s.step -= 1 }.opacity(s.step > 0 && !s.fixMode ? 1 : 0).disabled(s.step == 0 || s.fixMode)
            Spacer()
            if !s.fixMode {
                HStack(spacing: 7) {
                    ForEach(0..<Self.steps, id: \.self) { i in
                        Circle().fill(i == s.step ? Color.primary.opacity(0.8) : Color.primary.opacity(0.18)).frame(width: 7, height: 7)
                    }
                }
            }
            Spacer()
            HStack(spacing: 12) {
                if s.step == 1 && s.access != .granted {
                    Button(s.fixMode ? "Not Now" : "Skip for now") { s.fixMode ? finish([]) : next() }
                        .buttonStyle(.link).font(.system(size: 12.5))
                }
                Button(primaryTitle, action: primary)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16)
        .background(Color.primary.opacity(0.03))
        .overlay(Divider(), alignment: .top)
    }

    var primaryTitle: String {
        if s.fixMode { return "Done" }
        switch s.step {
        case 0: return "Get Started"
        case Self.steps - 1: return "Finish"
        default: return "Continue"
        }
    }

    var canContinue: Bool {
        switch s.step {
        case 1: return s.access == .granted
        case 2:
            if s.engine == .claude { return antFound || s.verify == .ok || (model.credential.storedKey && !s.replacingKey) }
            return true
        default: return true
        }
    }

    func primary() {
        if s.fixMode { model.recheck(); finish([]); return }
        if s.step == 2 { saveEngine() }
        if s.step == Self.steps - 1 { complete() } else { next() }
    }

    func next() { s.step = min(s.step + 1, Self.steps - 1) }

    // MARK: Actions

    func appear() {
        if s.presetForSnapshot { return }
        if model.credential.any { s.engine = .claude }
        if s.appleReady { s.engine = .apple }
        if model.config.backend == "vision" { s.engine = .vision }
        if Permissions.didAsk { probe() }
    }

    func askAccess() {
        Permissions.didAsk = true
        s.access = .checking
        probe()
    }

    func probe() {
        Permissions.probe(model.folder) { ok in
            if ok { granted() } else { s.access = .denied }
        }
    }

    func granted() {
        if s.access != .granted { s.access = .granted; model.recheck() }
    }

    func verifyKey() {
        let key = s.key.trimmingCharacters(in: .whitespacesAndNewlines)
        s.verify = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ClaudeAuth.validate(key: key)
            DispatchQueue.main.async {
                switch result {
                case .valid:
                    do {
                        try CredentialStore().storeAPIKey(key)
                        UserDefaults.standard.set(String(key.suffix(4)), forKey: "apiKeySuffix")
                        UserDefaults.standard.set(Date(), forKey: "apiKeyVerified")
                        s.verify = .ok
                        model.credentialsChanged()
                    } catch {
                        s.verify = .failed("Couldn't save the key: \(error.localizedDescription)")
                    }
                case .rejected(let why), .unreachable(let why):
                    s.verify = .failed(why)
                }
            }
        }
    }

    func saveEngine() {
        let backend = switch s.engine {
        case .apple: "auto"
        case .claude: "claude"
        case .vision: "vision"
        case .auto: "auto"
        }
        model.updateConfig { $0.backend = backend }
    }

    func setNotify(_ on: Bool) {
        guard on else { s.notify = false; model.updateConfig { $0.watchNotify = false }; return }
        NotificationPermission.request { ok in
            s.notify = ok
            s.notifyNote = ok ? nil : "Notifications are off for BetterAirdrop in System Settings → Notifications."
            model.updateConfig { $0.watchNotify = ok }
        }
    }

    func countBacklog() {
        let config = model.config, folder = model.folder
        DispatchQueue.global(qos: .userInitiated).async {
            var o = Watcher.Options(folder: folder)
            o.backlog = true
            o.airdropOnly = true
            let w = Watcher(options: o, planner: Planner(config: config), committer: Committer(config: config))
            let files = w.scan().filter { $0.pathExtension.lowercased() != "mov" }
            DispatchQueue.main.async { s.backlogFiles = files }
        }
    }

    func complete() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        if !s.notify { model.updateConfig { $0.watchNotify = false } }
        if s.launchAtLogin != LoginItem.isEnabled { LoginItem.set(s.launchAtLogin) }
        finish(s.backlog ? s.backlogFiles : [])
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}

// MARK: - Pieces

struct Feature: View {
    let symbol: String, color: Color, title: String, detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(color))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct FolderIcon: View {
    var body: some View {
        Image(systemName: "folder.fill").font(.system(size: 24)).foregroundStyle(Color(nsColor: NSColor(hex: 0x5aaef7)))
            .overlay(Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).offset(y: 2))
    }
}

struct EngineCard: View {
    let choice: EngineChoice
    @Binding var selected: EngineChoice
    let enabled: Bool
    let title: String
    let detail: String
    let badge: (String, Color)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected == choice ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15)).foregroundStyle(selected == choice ? Color.accentColor : Color.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .opacity(enabled ? 1 : 0.5)
            Spacer(minLength: 8)
            Text(badge.0).font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(badge.1 == .gray ? Color.secondary : badge.1)
                .background(RoundedRectangle(cornerRadius: 5).fill(badge.1.opacity(0.13)))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { selected = choice } }
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 44)
    }
}

/// A little strip of menu bar with our icon in it, for the last step.
struct MenuBarHint: View {
    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(systemName: "chevron.up").font(.system(size: 10))
            Image(nsImage: Art.menuBarGlyph()).renderingMode(.template)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
                .overlay(alignment: .topLeading) {
                    Text("↑ BetterAirdrop").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                        .fixedSize().offset(x: 6, y: 30)
                }
            Image(systemName: "wifi").font(.system(size: 11))
            Text(Date.now, format: .dateTime.weekday().hour().minute()).font(.system(size: 12))
        }
        .padding(.horizontal, 12).frame(width: 300, height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .padding(.bottom, 22)
    }
}
