import AppKit
import BetterAirdropCore
import BetterAirdropKit
import SwiftUI

/// Settings → General → Setup: welcome and folder access on one screen, then the naming engine.
/// Launch at login and notifications are on by default (Settings changes them), so they aren't
/// steps. Also opened at the access screen alone ("Fix…") when the permission goes missing. The
/// first launch itself shows none of this (AppDelegate.firstRun).
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

    let fixMode: Bool
    @Published private(set) var apple = AppleIntelligenceStatus.current
    var appleReady: Bool { apple.isAvailable }
    var presetForSnapshot = false
    init(fixMode: Bool) {
        self.fixMode = fixMode
    }

    /// Re-reads Apple Intelligence's status (it changes when it's turned on or the model finishes downloading).
    func refreshApple() {
        let now = AppleIntelligenceStatus.current
        if now != apple { apple = now }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @StateObject var s: OnboardingState
    let finish: () -> Void
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// `state` lets snapshots start at a given step with given answers.
    init(model: AppModel, fixMode: Bool = false, state: OnboardingState? = nil, finish: @escaping () -> Void) {
        self.model = model
        _s = StateObject(wrappedValue: state ?? OnboardingState(fixMode: fixMode))
        self.finish = finish
    }

    static let steps = 2

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch s.step {
                case 0: accessStep
                default: engineStep
                }
            }
            .padding(.horizontal, 44).padding(.top, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: 620, height: 500)
        .onAppear(perform: appear)
        .onReceive(poll) { _ in
            if s.step == 0 && Permissions.didAsk && s.access != .granted { probe() }
            if s.step == 1 && !s.appleReady { s.refreshApple() }
        }
    }

    // MARK: Steps

    /// Welcome and the one permission, on one screen (the fix window shows just the permission).
    var accessStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            if s.fixMode {
                Text("Let BetterAirdrop see your \(model.folderName)").font(.system(size: 22, weight: .bold)).padding(.vertical, 6)
            } else {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage ?? Art.appIcon()).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Welcome to BetterAirdrop").font(.system(size: 22, weight: .bold))
                        Text("AirDropped photos get names you can search for, instead of IMG_4821.HEIC.").font(.system(size: 13))
                    }
                }
                .padding(.bottom, 18)
            }
            Text("macOS asks once whether BetterAirdrop may read and rename files in \(model.folderName), where AirDrop saves them.")
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
                    case .notAsked: Button("Allow Access…", action: askAccess).buttonStyle(.borderedProminent)
                    case .denied: EmptyView()   // macOS won't ask again; the row below says what to do
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                if s.access == .denied {
                    Divider()
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Access is off").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.red)
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
            Text("Only files AirDrop delivers are renamed, and every rename can be undone. Nothing in \(model.folderName) is uploaded.")
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
                           detail: s.appleReady ? "On-device and private. Names are good, not great." : s.apple.message,
                           badge: ("On-device · Free", .green))
                if let url = s.apple.settingsURL {
                    Button("Open Apple Intelligence Settings…") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link).font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 42).padding(.bottom, 10)
                }
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
            Text("What gets sent: a 768 px copy of each photo with **no location or camera data**, plus the city name and any text in it. If Claude can't be reached, Apple Vision names the photo instead.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 42).padding(.trailing, 12).padding(.bottom, 12)
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
                if s.step == 0 && s.access != .granted {
                    Button(s.fixMode ? "Not Now" : "Skip for now") { s.fixMode ? finish() : next() }
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
        return s.step == Self.steps - 1 ? "Done" : "Continue"
    }

    var canContinue: Bool {
        switch s.step {
        case 0: return s.access == .granted
        case 1:
            if s.engine == .claude { return antFound || s.verify == .ok || (model.credential.storedKey && !s.replacingKey) }
            return true
        default: return true
        }
    }

    func primary() {
        if s.fixMode { model.recheck(); finish(); return }
        if s.step == 1 { saveEngine() }
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
        if s.access != .granted { s.access = .granted; model.folderAccess = true; model.recheck(); model.reportState() }
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

    func complete() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        finish()
    }
}

// MARK: - Pieces

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
