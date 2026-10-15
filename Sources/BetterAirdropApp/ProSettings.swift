import AppKit
import BetterAirdropCore
import BetterAirdropKit
import SwiftUI

// MARK: - Settings → Pro

/// The license (status, key, Activate / Deactivate, Buy) and the Pro watchers. Without Pro the
/// controls are shown disabled with a "Pro" tag and one line linking to Buy; nothing pops up.
struct ProPane: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var working = false
    @State private var message: (text: String, error: Bool)?
    @State private var folderNote: String?

    var body: some View {
        Form {
            Section("BetterAirdrop Pro") {
                LabeledContent {
                    ProStatusBadge(status: model.proStatus)
                } label: {
                    Text("Status")
                    Text(statusDetail)
                }
                if model.license == nil || model.proStatus == .lapsed {
                    LabeledContent {
                        HStack(spacing: 6) {
                            TextField("", text: $key, prompt: Text("License key"))
                                .labelsHidden().font(.system(size: 12, design: .monospaced)).frame(width: 230)
                                .onSubmit(activate)
                            Button(working ? "Activating…" : "Activate", action: activate)
                                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || working)
                        }
                    } label: {
                        Text("License key")
                        Text("From your Polar receipt email. Activating uses one of its 3 Macs.")
                    }
                } else {
                    LabeledContent {
                        Button(working ? "Deactivating…" : "Deactivate This Mac", action: deactivate).disabled(working)
                    } label: {
                        Text("This Mac")
                        Text("“\(model.license?.label ?? "")” · frees one of the key's 3 Macs")
                    }
                }
                if let message {
                    Text(message.text).font(.system(size: 11.5)).foregroundStyle(message.error ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.isPro {
                    LabeledContent {
                        BuyButton()
                    } label: {
                        Text("$19 once · 3 Macs · lifetime updates")
                        Text("Everything BetterAirdrop does today stays free.")
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { model.config.watchScreenshots }, set: { v in model.updateConfig { $0.watchScreenshots = v } })) {
                    HStack(spacing: 6) { Text("Also name new screenshots"); if !model.isPro { ProTag() } }
                    Text("Screenshots saved to \(AppModel.tilde(model.screenshotFolder)), named with the same engine. \(accessText(model.screenshotFolder))")
                }
                .disabled(!model.isPro)
                ForEach(model.config.watchExtraFolders, id: \.self) { path in
                    LabeledContent {
                        Button("Remove") { model.updateConfig { $0.watchExtraFolders.removeAll { $0 == path } } }
                    } label: {
                        Text(path)
                        Text(accessText(AppModel.expand(path)).isEmpty ? "New photos here are named." : accessText(AppModel.expand(path)))
                    }
                    .disabled(!model.isPro)
                }
                LabeledContent {
                    Button("Add Folder…", action: addFolder).disabled(!model.isPro)
                } label: {
                    HStack(spacing: 6) { Text("Other folders"); if !model.isPro { ProTag() } }
                    Text(folderNote ?? "New images saved to these folders are named too. What's already there is left alone.")
                }
            } header: {
                Text("Watch more")
            } footer: {
                if !model.isPro { ProLine() }
            }
            FilingSection(model: model)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshLicense() }
    }

    var statusDetail: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        switch model.proStatus {
        case .free: return Polar.canBuy ? "Not activated on this Mac." : "Pro isn't on sale yet."
        case .active:
            let checked = model.license?.lastValidatedAt.map { " · checked \(Calendar.current.isDateInToday($0) ? "today" : RelativeTime.string($0))" } ?? ""
            return "Key \(model.license?.maskedKey ?? "") on this Mac\(checked)"
        case .grace(let until): return "Polar says this key is no longer valid. Pro stays on until \(f.string(from: until))."
        case .lapsed: return "Polar says key \(model.license?.maskedKey ?? "") is no longer valid, so Pro is off. Activate a valid key to turn it back on."
        }
    }

    /// "", or why a Pro watcher isn't running ("No access yet…").
    func accessText(_ folder: URL) -> String {
        guard model.isPro, let s = model.proWatchStates[folder.path] else { return "" }
        switch s {
        case .noAccess: return "BetterAirdrop can't read this folder: allow it in System Settings → Privacy & Security → Files and Folders."
        case .paused: return "Paused."
        default: return ""
        }
    }

    func activate() {
        let k = key
        guard !k.trimmingCharacters(in: .whitespaces).isEmpty, !working else { return }
        working = true
        message = nil
        model.activateLicense(k) { error in
            working = false
            if let error { message = (error, true) } else {
                key = ""
                message = ("Pro is on. Thank you!" + (model.engine.isHosted ? "\n" + EngineStatus.hostedNotice : ""), false)
            }
        }
    }

    func deactivate() {
        working = true
        message = nil
        model.deactivateLicense { error in
            working = false
            message = error.map { ($0, true) } ?? ("Deactivated. The key can be used on another Mac.", false)
        }
    }

    func addFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose a folder. New photos saved there will be named as they arrive."
        panel.prompt = "Watch Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        let key = WatchPlan.key
        if key(url) == key(model.folder) { folderNote = "\(model.folderName) is already watched for AirDrops."; return }
        let path = AppModel.tilde(url)
        guard !model.config.watchExtraFolders.contains(where: { key(AppModel.expand($0)) == key(url) }) else { return }
        folderNote = nil
        model.updateConfig { $0.watchExtraFolders.append(path) }
    }
}

struct ProStatusBadge: View {
    let status: ProStatus
    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .free: ("Free", .secondary)
        case .active: ("Pro", .green)
        case .grace: ("Pro (check failed)", .orange)
        case .lapsed: ("Off", .red)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

/// The small "PRO" tag next to a gated control.
struct ProTag: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
    }
}

/// "Buy Pro ↗", or "Coming soon" while the checkout link is still the placeholder.
struct BuyButton: View {
    var body: some View {
        if Polar.canBuy, let url = URL(string: Polar.checkoutURL) {
            Link("Buy Pro ↗", destination: url).buttonStyle(.bordered)
        } else {
            Text("Coming soon").foregroundStyle(.secondary)
        }
    }
}

/// The one line under gated controls (and, with its own text, the free tier's hosted-naming line).
struct ProLine: View {
    var text = "Part of BetterAirdrop Pro, $19 once."
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            if Polar.canBuy, let url = URL(string: Polar.checkoutURL) {
                Link("Buy Pro ›", destination: url)
            } else {
                Text("Coming soon.")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

// MARK: - Settings → Pro → File by kind

/// One rule per kind: a folder, or "stays where it arrived". Off by default.
struct FilingSection: View {
    @ObservedObject var model: AppModel
    static let kinds: [(Kind, String)] = [(.photo, "Photos"), (.screenshot, "Screenshots"), (.receipt, "Receipts"),
                                          (.document, "Documents"), (.whiteboard, "Whiteboards")]
    static var thisMonth: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }

    var body: some View {
        Section {
            ForEach(Self.kinds, id: \.0) { kind, title in
                LabeledContent {
                    HStack(spacing: 6) {
                        if model.config.fileFolders[kind.rawValue] != nil {
                            Button("Don't Move") { model.updateConfig { $0.fileFolders[kind.rawValue] = nil } }
                        }
                        Button("Choose…") { choose(kind, title) }
                    }
                } label: {
                    Text(title)
                    Text(model.config.fileFolders[kind.rawValue].map { "→ \($0)\(model.config.fileMonthly ? "/\(Self.thisMonth)" : "")" } ?? "Stay where they arrive")
                }
            }
            Toggle(isOn: Binding(get: { model.config.fileMonthly }, set: { v in model.updateConfig { $0.fileMonthly = v } })) {
                Text("A folder for each month")
                Text("Receipts/\(Self.thisMonth)/…, from the photo's date.")
            }
        } header: {
            HStack(spacing: 6) { Text("File by kind"); if !model.isPro { ProTag() } }
        } footer: {
            if model.isPro {
                Text("New arrivals are moved as they're renamed, and Undo puts them back. Photos you rename by hand stay where they are.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ProLine()
            }
        }
        .disabled(!model.isPro)
    }

    func choose(_ kind: Kind, _ title: String) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose where new \(title.lowercased()) go."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        let path = AppModel.tilde(url)
        model.updateConfig { $0.fileFolders[kind.rawValue] = path }
    }
}

// MARK: - Settings → Naming → Name builder

/// Pick the parts of a name, their order, the separator and the date format; it writes an ordinary
/// template (the text field above, which stays free) and `date_format`.
struct NameBuilderSection: View {
    @ObservedObject var model: AppModel
    @Binding var template: String

    var builder: NameBuilder { NameBuilder(template: template) ?? .standard }
    var isCustom: Bool { NameBuilder(template: template) == nil }

    var body: some View {
        Section {
            VStack(spacing: 0) {
                ForEach(Array(builder.rows.enumerated()), id: \.element.part) { i, row in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { row.on }, set: { _ in change { $0.toggle(row.part) } })) {
                            Text(row.part.title).foregroundStyle(row.on ? .primary : .secondary)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(row.part == .description)
                        if row.part == .description { Text("always included").font(.system(size: 11)).foregroundStyle(.secondary) }
                        Spacer()
                        if row.on {
                            Button { change { $0.move(row.part, by: -1) } } label: { Image(systemName: "chevron.up") }
                                .disabled(i == 0).help("Earlier in the name")
                            Button { change { $0.move(row.part, by: 1) } } label: { Image(systemName: "chevron.down") }
                                .disabled(i == builder.parts.count - 1).help("Later in the name")
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 4)
                    if i < builder.rows.count - 1 { Divider() }
                }
            }
            Picker("Separator", selection: Binding(get: { builder.separator }, set: { s in change { $0.separator = s } })) {
                ForEach(NameBuilder.Separator.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Date", selection: Binding(get: { model.config.dateFormat }, set: { f in model.updateConfig { $0.dateFormat = f } })) {
                ForEach(DateFormat.allCases, id: \.self) { f in Text(f.apply(TemplatePreview.sample["date"]!)).tag(f) }
            }
        } header: {
            HStack(spacing: 6) { Text("Name builder"); if !model.isPro { ProTag() } }
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                if model.isPro && isCustom {
                    Text("Your template is hand-written; changing a part here replaces it.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !model.isPro { ProLine() }
            }
        }
        .disabled(!model.isPro)
    }

    func change(_ edit: (inout NameBuilder) -> Void) {
        var b = builder
        edit(&b)
        template = b.template
    }
}
