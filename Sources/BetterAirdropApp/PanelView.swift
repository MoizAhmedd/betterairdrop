import AppKit
import BetterAirdropCore
import BetterAirdropKit
import SwiftUI

/// What the panel (and the rest of the UI) can ask the app to do. Implemented by `AppDelegate`.
@MainActor
protocol PanelActions: AnyObject {
    func renameFiles(_ urls: [URL])
    func chooseFilesToRename()
    func openFolder()
    func showHistory()
    func showSettings()
    func fixAccess()
    func undo(_ selection: Undoer.Selection)
    func reveal(_ paths: [String])
    func redo(_ item: RecentItem)
    func previewBacklog()
    func addClaudeKey()
    func quit()
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            bars
            firstRunRows
            HStack {
                Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let id = model.lastUndoableID {
                    Button("Undo last batch (\(model.lastUndoableCount))") { actions.undo(.batch(id)) }
                        .buttonStyle(.link).font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 3)
            if model.recent.isEmpty {
                Text("Nothing yet. AirDrop a photo to this Mac and it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                ForEach(model.recent) { item in RecentRow(item: item, actions: actions) }
            }
            Divider().padding(.horizontal, 10).padding(.vertical, 5)
            MenuRow(title: "Rename Files…", shortcut: "⌘R") { actions.chooseFilesToRename() }
                .keyboardShortcut("r", modifiers: .command)
            MenuRow(title: "Open \(model.folderName)", shortcut: "⇧⌘L") { actions.openFolder() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            MenuRow(title: "Show All History…") { actions.showHistory() }
            PauseMenuRow(model: model)
            Divider().padding(.horizontal, 10).padding(.vertical, 5)
            MenuRow(title: "Settings…", shortcut: "⌘,") { actions.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
            MenuRow(title: "Quit BetterAirdrop", shortcut: "⌘Q") { actions.quit() }
                .keyboardShortcut("q", modifiers: .command)
            HStack {
                Text("\(Self.monthName): \(model.stats.photos) photo\(model.stats.photos == 1 ? "" : "s")")
                Spacer()
                if model.stats.costUSD > 0 { Text(String(format: "Claude spend ≈ $%.2f", model.stats.costUSD)) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
        }
        .padding(6)
        .frame(width: 340)
    }

    static var monthName: String {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMM"); return f.string(from: Date())
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? Art.appIcon(size: 64))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(model.statusLine).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if model.busy { ProgressView().controlSize(.mini) }
                }
                Text(model.engineLine).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { !model.isPaused }, set: { $0 ? model.resume() : model.pause(.indefinitely) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help(model.isPaused ? "Resume" : "Pause")
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 10)
    }

    var dotColor: Color {
        switch model.state {
        case .watching: model.isPaused ? .gray : .green
        case .noAccess: .orange
        case .paused, .stopped, .lockedByOther: .gray
        }
    }

    @ViewBuilder var bars: some View {
        if model.state == .noAccess && !model.isPaused {
            AlertBar(text: "⚠︎ BetterAirdrop can't read \(model.folderName) any more. AirDrops aren't being renamed.",
                     button: "Fix…", tint: Color(nsColor: NSColor(hex: 0xfff1d6)), fg: Color(nsColor: NSColor(hex: 0x6a4000))) { actions.fixAccess() }
        } else if model.isPaused {
            AlertBar(text: PauseText.banner(until: model.pausedUntil), button: "Resume",
                     tint: Color.primary.opacity(0.06), fg: .primary) { model.resume() }
        } else if model.state == .lockedByOther {
            AlertBar(text: "`betterairdrop watch` is running in Terminal, so the app is standing by.", button: "Retry",
                     tint: Color.primary.opacity(0.06), fg: .primary) { model.recheck() }
        }
    }
}

extension PanelView {
    /// The first-run offers: a key found in the shell, the "add a key" nudge, old photos to preview.
    @ViewBuilder var firstRunRows: some View {
        if model.shellKeyOffer {
            VStack(alignment: .leading, spacing: 6) {
                Text("Found `ANTHROPIC_API_KEY` in your shell. Use it for photo names?")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if let e = model.shellKeyError {
                    Text(e).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(model.shellKeyChecking ? "Checking…" : "Use It") { model.acceptShellKey() }
                        .controlSize(.small).buttonStyle(.borderedProminent).disabled(model.shellKeyChecking)
                    Button("No Thanks") { model.declineShellKey() }.controlSize(.small)
                    Spacer()
                    Text("saved to your Keychain").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
            .padding(.horizontal, 4).padding(.bottom, 6)
        } else if model.showKeyNudge {
            Button { actions.addClaudeKey() } label: {
                Text("Better names: add a Claude key ›").font(.system(size: 11.5))
            }
            .buttonStyle(.link).padding(.horizontal, 10).padding(.bottom, 6)
        }
        if !model.backlog.isEmpty && model.state == .watching {
            MenuRow(title: "Found \(model.backlog.count) unnamed photo\(model.backlog.count == 1 ? "" : "s") in \(model.folderName)…") {
                actions.previewBacklog()
            }
        }
    }
}

struct AlertBar: View {
    let text: String
    let button: String
    let tint: Color
    let fg: Color
    let action: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(.init(text)).font(.system(size: 12)).foregroundStyle(fg).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint))
        .padding(.horizontal, 4).padding(.bottom, 6)
    }
}

struct RecentRow: View {
    let item: RecentItem
    let actions: PanelActions
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            ThumbnailView(path: item.currentPath)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.undone ? item.oldName : item.newName)
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .strikethrough(item.undone, color: .secondary)
                Text(item.detail()).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if hover || item.undone {
                HStack(spacing: 4) {
                    if item.undone {
                        IconButton(symbol: "arrow.clockwise", help: "Redo: name it again") { actions.redo(item) }
                    } else {
                        IconButton(symbol: "arrow.uturn.backward", help: "Undo") { actions.undo(.file(item.target)) }
                    }
                    IconButton(symbol: "magnifyingglass", help: "Show in Finder") { actions.reveal([item.currentPath]) }
                }
            }
        }
        .opacity(item.undone ? 0.65 : 1)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(item.newName)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain).help(help)
    }
}

/// A menu-style row: blue highlight on hover, shortcut on the right.
struct MenuRow: View {
    let title: String
    var shortcut: String?
    var trailing: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if let s = shortcut ?? trailing {
                    Text(s).font(.system(size: 12)).foregroundStyle(hover ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .foregroundStyle(hover ? Color.white : Color.primary)
            .padding(.horizontal, 10).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// "Pause ›": a menu row that pops up the three durations beside itself.
struct PauseMenuRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        MenuRow(title: "Pause", trailing: "›") {
            let menu = NSMenu()
            for d in PauseDuration.allCases {
                menu.addItem(ClosureMenuItem(d.title) { model.pause(d) })
            }
            if model.isPaused {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Resume Now") { model.resume() })
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
