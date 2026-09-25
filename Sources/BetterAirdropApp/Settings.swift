import AppKit
import BetterAirdropCore
import BetterAirdropKit
import Security
import SwiftUI

/// Settings (UX mockup e): an AppKit window with toolbar tabs, each pane a SwiftUI grouped form.
/// Every control writes ~/.config/betterairdrop/config.toml (through `AppModel.updateConfig`), so
/// the CLI and the app never disagree. The API key is the exception: it lives in its own 0600 file (CredentialStore).
@MainActor
enum SettingsWindow {
    enum Pane: Int, CaseIterable {
        case general, naming, advanced, about
        var title: String { ["General", "Naming", "Advanced", "About"][rawValue] }
        var symbol: String { ["gearshape", "tag", "slider.horizontal.3", "info.circle"][rawValue] }
    }

    static func make(model: AppModel, app: AppDelegate) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for pane in Pane.allCases {
            let root: AnyView = switch pane {
            case .general: AnyView(GeneralPane(model: model, app: app))
            case .naming: AnyView(NamingPane(model: model))
            case .advanced: AnyView(AdvancedPane(model: model, app: app))
            case .about: AnyView(AboutPane(updater: app.updater))
            }
            let vc = NSHostingController(rootView: root.frame(width: 620))
            vc.sizingOptions = [.preferredContentSize]
            vc.title = pane.title
            let item = NSTabViewItem(viewController: vc)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var model: AppModel
    let app: AppDelegate
    @State private var login = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var showInMenuBar = UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true
    @State private var access: Bool?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { login }, set: { on in
                    loginError = LoginItem.set(on)
                    login = LoginItem.isEnabled
                })) {
                    Text("Open BetterAirdrop at login")
                    if let loginError { Text(loginError).foregroundStyle(.red) }
                    else if LoginItem.needsApproval { Text("Waiting for approval in System Settings → General → Login Items.") }
                }
                Toggle(isOn: Binding(get: { showInMenuBar }, set: { v in
                    showInMenuBar = v
                    UserDefaults.standard.set(v, forKey: "showInMenuBar")
                    model.objectWillChange.send()
                })) {
                    Text("Show in menu bar")
                    Text("When hidden, open BetterAirdrop again to see Settings.")
                }
            }
            Section("Watching") {
                LabeledContent {
                    Button("Change…", action: chooseFolder)
                } label: {
                    Text("Folder")
                    HStack(spacing: 3) {
                        Text("\(model.folderDisplayPath) ·")
                        switch access {
                        case .some(true): Text("✓ access granted").foregroundStyle(.green)
                        case .some(false): Text("not allowed").foregroundStyle(.red)
                        case .none: Text("checking…")
                        }
                    }
                }
                Toggle(isOn: bind(\.watchAirdropOnly)) {
                    Text("Only rename files from AirDrop")
                    Text("Other downloads are never touched.")
                }
                Picker("Notifications", selection: Binding(get: { model.config.watchNotify }, set: setNotify)) {
                    Text("After each batch").tag(true)
                    Text("Never").tag(false)
                }
            }
            Section {
                LabeledContent {
                    Button("Open Setup…") { app.showOnboarding() }
                } label: {
                    Text("Setup")
                    Text("Folder access, the naming engine and your Claude key, step by step.")
                }
            }
            Section("Files") {
                Toggle(isOn: bind(\.convertHEIC)) {
                    Text("Convert HEIC to JPEG")
                    Text("JPEGs drop HDR and depth data, and Photos no longer pairs a Live Photo's still with its video.")
                }
                Picker("Originals", selection: bind(\.originals)) {
                    Text("Move to Trash").tag(Config.Originals.trash)
                    Text("Keep next to the JPEG").tag(Config.Originals.keep)
                    Text("Delete").tag(Config.Originals.delete)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            login = LoginItem.isEnabled
            Permissions.probe(model.folder) { access = $0 }
        }
    }

    func bind<T>(_ key: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: key] }, set: { v in model.updateConfig { $0[keyPath: key] = v } })
    }

    func setNotify(_ on: Bool) {
        guard on else { model.updateConfig { $0.watchNotify = false }; return }
        NotificationPermission.request { ok in
            model.updateConfig { $0.watchNotify = ok }
            if !ok { NotificationPermission.openSettings() }
        }
    }

    func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose the folder AirDrop saves to (usually Downloads)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = model.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
        model.updateConfig { $0.watchFolder = path }
        access = nil
        Permissions.probe(url) { access = $0 }
    }
}

// MARK: - Naming

struct NamingPane: View {
    @ObservedObject var model: AppModel
    @State private var template = ""
    @State private var editingKey = false
    @State private var perKind = false

    static let models = [("claude-haiku-4-5", "Claude Haiku 4.5"), ("claude-sonnet-4-5", "Claude Sonnet 4.5")]

    var body: some View {
        Form {
            Section("Naming engine") {
                Picker(selection: engineBinding) {
                    ForEach([EngineChoice.auto, .apple, .claude, .vision], id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Engine")
                    Text("Automatic uses Apple Intelligence when it's available, then Claude, then Apple Vision.")
                }
                LabeledContent("Now using") {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text(model.engine.name)
                        if let d = model.engine.detail { Text("· \(d)").foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Claude") {
                LabeledContent {
                    HStack {
                        Button(model.credential.storedKey ? "Replace…" : "Add…") { editingKey = true }
                        if model.credential.storedKey {
                            Button("Remove", role: .destructive) {
                                CredentialStore(legacy: .none).deleteAPIKey()
                                Keychain.deleteAPIKey()
                                UserDefaults.standard.removeObject(forKey: "apiKeySuffix")
                                model.credentialsChanged()
                            }
                        }
                    }
                } label: {
                    Text("API key")
                    Text(keyState)
                }
                LabeledContent("Don't have one?") {
                    Link("Get a key ↗", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                }
                LabeledContent {
                    Text(model.credential.antPath == nil ? "Not installed" : model.credential.antLoggedIn ? "Logged in" : "Not logged in")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Anthropic CLI login")
                    Text(model.credential.antPath.map { "Used if there's no key. Found at \($0)." } ?? "Used if there's no key. Install with `brew install anthropics/tap/ant`.")
                }
                Picker("Model", selection: bind(\.claudeModel)) {
                    ForEach(modelChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent {
                    Text("\(model.stats.photos) photo\(model.stats.photos == 1 ? "" : "s") · ≈ \(String(format: "$%.2f", model.stats.costUSD))")
                } label: {
                    Text("This month")
                    Text("at Anthropic's list price, worked out from the tokens actually used")
                }
            }
            Section("Name format") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Template", text: $template)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveTemplate)
                        .onChange(of: template) { _ in saveTemplate() }
                    HStack(spacing: 5) {
                        ForEach(TemplatePreview.tokens, id: \.self) { t in
                            Button("{\(t)}") { template += (template.hasSuffix("_") || template.isEmpty ? "" : "_") + "{\(t)}" }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .foregroundStyle(Color.accentColor)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    Group {
                        switch TemplatePreview.render(template) {
                        case .success(let name): Text(name)
                        case .failure(let e): Text("\(e)").foregroundStyle(.red)
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    HStack(spacing: 4) {
                        Text("Screenshots, receipts and documents have their own formats.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Edit per kind…") { perKind = true }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { template = model.config.template; model.refreshCredential() }
        .sheet(isPresented: $editingKey) { KeySheet(model: model) }
        .sheet(isPresented: $perKind) { KindTemplatesSheet(model: model) }
    }

    var modelChoices: [(String, String)] {
        Self.models.contains { $0.0 == model.config.claudeModel } ? Self.models
            : Self.models + [(model.config.claudeModel, EngineStatus.modelName(model.config.claudeModel))]
    }

    var keyState: String {
        guard model.credential.storedKey else { return "None stored" }
        var s = "Saved on this Mac"
        if let suffix = UserDefaults.standard.string(forKey: "apiKeySuffix") { s += " · sk-ant-…\(suffix)" }
        if let d = UserDefaults.standard.object(forKey: "apiKeyVerified") as? Date {
            s += " · verified " + (Calendar.current.isDateInToday(d) ? "today" : RelativeTime.string(d))
        }
        return s
    }

    var engineBinding: Binding<EngineChoice> {
        Binding(get: { EngineChoice(rawValue: model.config.backend) ?? .auto },
                set: { c in model.updateConfig { $0.backend = c.rawValue } })
    }

    func bind<T>(_ key: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: key] }, set: { v in model.updateConfig { $0[keyPath: key] = v } })
    }

    func saveTemplate() {
        guard case .success = TemplatePreview.render(template), template != model.config.template else { return }
        let t = template
        model.updateConfig { $0.template = t }
    }
}

struct KeySheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var key = ""
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Anthropic API key").font(.headline)
            SecureField("Paste your API key (sk-ant-…)", text: $key).font(.system(size: 12, design: .monospaced)).frame(width: 380)
            if let status { Text(status).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Link("Get a key ↗", destination: URL(string: "https://platform.claude.com/settings/keys")!).font(.system(size: 12))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(checking ? "Verifying…" : "Verify and Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty || checking)
            }
        }
        .padding(20)
    }

    func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        DispatchQueue.global().async {
            let r = ClaudeAuth.validate(key: k)
            DispatchQueue.main.async {
                checking = false
                switch r {
                case .valid:
                    do {
                        try CredentialStore().storeAPIKey(k)
                        UserDefaults.standard.set(String(k.suffix(4)), forKey: "apiKeySuffix")
                        UserDefaults.standard.set(Date(), forKey: "apiKeyVerified")
                        model.credentialsChanged()
                        dismiss()
                    } catch { status = error.localizedDescription }
                case .rejected(let why), .unreachable(let why): status = why
                }
            }
        }
    }
}

struct KindTemplatesSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var values: [String: String] = [:]
    static let kinds = ["screenshot", "receipt", "document", "whiteboard"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name format per kind").font(.headline)
            ForEach(Self.kinds, id: \.self) { k in
                HStack {
                    Text(k.capitalized).frame(width: 90, alignment: .leading)
                    TextField("", text: Binding(get: { values[k] ?? "" }, set: { values[k] = $0 }))
                        .font(.system(size: 12, design: .monospaced)).frame(width: 300)
                    Image(systemName: valid(values[k] ?? "") ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(valid(values[k] ?? "") ? .green : .red)
                }
            }
            Text("Tokens: {date} {time} {place} {country} {subject} {kind} {device} {merchant} {total} {orig}")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let v = values
                    model.updateConfig { c in for (k, t) in v where (try? Template(t)) != nil { c.kindTemplates[k] = t } }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.kinds.allSatisfy { valid(values[$0] ?? "") })
            }
        }
        .padding(20)
        .onAppear { values = model.config.kindTemplates }
    }

    func valid(_ t: String) -> Bool { (try? Template(t)) != nil }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @ObservedObject var model: AppModel
    let app: AppDelegate
    @State private var cli: CLILink.Status = .notInstalled
    @State private var cliError: String?
    @State private var entries = 0
    @State private var recheck: String?
    @State private var uninstalling = false
    @State private var copied = false

    var link: CLILink {
        CLILink(target: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/betterairdrop"))
    }

    var body: some View {
        Form {
            Section("Command-line tool") {
                LabeledContent {
                    switch cli {
                    case .installed: Button("Remove") { link.remove(); refresh() }
                    case .foreign: EmptyView()
                    default: Button("Install") {
                        do { try link.install(); cliError = nil } catch { cliError = error.localizedDescription }
                        refresh()
                    }
                    }
                } label: {
                    Text("`betterairdrop` in Terminal")
                    Text(cliText)
                    if let cliError { Text(cliError).foregroundStyle(.red) }
                }
            }
            Section("Privacy") {
                Picker(selection: Binding(get: { model.config.placeProvider == .none ? Config.PlaceProvider.none : .offline },
                                          set: { v in model.updateConfig { $0.placeProvider = v } })) {
                    Text("Offline (city)").tag(Config.PlaceProvider.offline)
                    Text("Off").tag(Config.PlaceProvider.none)
                } label: {
                    Text("Place names")
                    Text("Offline uses a built-in list of cities, so coordinates never leave the Mac.")
                }
                Toggle("Remove location from renamed photos", isOn: Binding(get: { model.config.stripGPSFromOutput },
                                                                         set: { v in model.updateConfig { $0.stripGPSFromOutput = v } }))
            }
            Section("History & troubleshooting") {
                LabeledContent {
                    Button("Show in Finder") {
                        let u = model.journal.url
                        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: u.path) ? u : u.deletingLastPathComponent()])
                    }
                } label: {
                    Text("Rename history")
                    Text("\(tilde(model.journal.url.path)) · \(entries) entr\(entries == 1 ? "y" : "ies")")
                }
                LabeledContent {
                    Button(copied ? "Copied ✓" : "Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Diagnostics.report(model: model), forType: .string)
                        copied = true
                    }
                } label: {
                    Text("Diagnostics")
                    Text("versions, permissions, engine status. No file names, no keys.")
                }
                LabeledContent {
                    Button("Re-check") {
                        recheck = "Checking…"
                        Permissions.probe(model.folder) { ok in
                            recheck = ok ? "✓ Access works." : "✗ Access is missing. Use Fix… in the menu."
                            model.recheck()
                        }
                    }
                } label: {
                    Text("\(model.folderName) permission")
                    Text(recheck ?? "Use this if access looks granted but renames stop.")
                }
            }
            Section {
                LabeledContent {
                    Button("Uninstall…", role: .destructive) { uninstalling = true }
                } label: {
                    Text("Uninstall BetterAirdrop")
                    Text("Removes the app, login item, CLI link and stored API key. Your renamed photos stay as they are.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
        .sheet(isPresented: $uninstalling) { UninstallSheet(app: app) }
    }

    var cliText: String {
        switch cli {
        case .installed: link.onPath() ? "Installed at ~/.local/bin/betterairdrop." : "Installed at ~/.local/bin/betterairdrop. Add ~/.local/bin to your PATH to use it."
        case .notInstalled: "Not installed. Adds a link at ~/.local/bin/betterairdrop (no password)."
        case .stale: "Points at another copy of the app. Install to update the link."
        case .foreign: "~/.local/bin/betterairdrop is another program; BetterAirdrop won't replace it."
        }
    }

    func refresh() {
        cli = link.status
        let j = model.journal
        DispatchQueue.global().async {
            let n = j.entries().count
            DispatchQueue.main.async { entries = n }
        }
    }

    func tilde(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

struct UninstallSheet: View {
    let app: AppDelegate
    @Environment(\.dismiss) var dismiss
    @State private var purge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Uninstall BetterAirdrop?").font(.headline)
            Text("This turns off the login item, removes the CLI link and the stored API key, resets the Downloads permission and moves BetterAirdrop to the Trash. Renamed photos stay renamed.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Also delete settings and rename history", isOn: $purge).toggleStyle(.switch).controlSize(.small)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) { app.uninstall(purge: purge) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - About

struct AboutPane: View {
    @ObservedObject var updater: Updater
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage ?? Art.appIcon()).resizable().frame(width: 96, height: 96).padding(.top, 20)
            Text("BetterAirdrop").font(.system(size: 20, weight: .semibold)).padding(.top, 10)
            Text("Version \(Self.version) · \(CodeSignature.describe())").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            HStack(spacing: 8) {
                Button("Check for Updates") {
                    if updater.isAvailable { updater.checkForUpdates() }
                    else { status = "This development build doesn't update itself. Releases will, through Sparkle." }
                }
                Link("GitHub ↗", destination: URL(string: "https://github.com/MoizAhmedd/betterairdrop")!).buttonStyle(.bordered)
                Link("Report an Issue ↗", destination: URL(string: "https://github.com/MoizAhmedd/betterairdrop/issues/new")!).buttonStyle(.bordered)
            }
            .padding(.top, 14)
            Text(status ?? " ").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
            Form {
                Toggle(isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 })) {
                    Text("Check for updates automatically")
                    Text("once a day. Updates are verified with BetterAirdrop's signing key before they're installed.")
                }
                Toggle("Install updates automatically", isOn: Binding(get: { updater.automaticallyInstalls }, set: { updater.automaticallyInstalls = $0 }))
            }
            .formStyle(.grouped)
            .disabled(!updater.isAvailable)
            .fixedSize(horizontal: false, vertical: true)
            Text("MIT License · City data © GeoNames, CC BY 4.0").font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 16)
        }
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}

/// How this copy of the app is signed ("ad-hoc signed", or the certificate's name).
enum CodeSignature {
    static func describe() -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return "unsigned" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "unsigned" }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            var name: CFString?
            SecCertificateCopyCommonName(leaf, &name)
            return "signed “\(name as String? ?? "unknown")”"
        }
        return "ad-hoc signed (development build)"
    }
}

/// Settings → Advanced → Copy Report. Versions, permission and engine state; never file names or keys.
@MainActor
enum Diagnostics {
    static func report(model: AppModel) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let c = model.config
        return """
        BetterAirdrop \(AboutPane.version), \(CodeSignature.describe())
        macOS \(os), \(machine())
        watching: \(model.folderIsDownloads ? "Downloads" : "a custom folder"), state \(model.state), paused \(model.isPaused)
        engine: backend \(c.backend) → \(model.engine.name)\(model.engine.detail.map { " (\($0))" } ?? ""), model \(c.claudeModel), claude.auto \(c.claudeInAuto)
        credential: stored \(model.credential.storedKey), env \(model.credential.environmentKey), ant \(model.credential.antPath == nil ? "not installed" : model.credential.antLoggedIn ? "logged in" : "not logged in")
        settings: airdrop_only \(c.watchAirdropOnly), notify \(c.watchNotify), convert_heic \(c.convertHEIC), originals \(c.originals.rawValue), place \(c.placeProvider.rawValue)
        login item: \(LoginItem.isEnabled ? "on" : "off"), updater: \(Updater.isConfigured ? "configured" : "not configured")
        this month: \(model.stats.photos) photos, $\(String(format: "%.2f", model.stats.costUSD))
        config error: \(model.configError == nil ? "none" : "yes")
        """
    }

    static func machine() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
