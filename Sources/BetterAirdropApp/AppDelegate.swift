import AppKit
import BetterAirdropCore
import BetterAirdropKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, PanelActions {
    let model = AppModel()
    let updater = Updater()
    var status: StatusItemController!
    var notifications: Notifications!
    var onboardingWindow: NSWindow?
    var historyWindow: NSWindow?
    var settingsWindow: NSWindow?
    var renameWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        status = StatusItemController(model: model, actions: self)
        notifications = Notifications(app: self)
        model.onBatch = { [weak self] b in self?.notifications.post(b) }
        model.onLostAccess = { [weak self] in
            guard let self, UserDefaults.standard.bool(forKey: "onboardingDone") else { return }
            self.notifications.postLostAccess()
        }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        model.start()
        if Snapshot.directory != nil {
            if ProcessInfo.processInfo.environment["BETTERAIRDROP_SNAPSHOT_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            runSnapshots()
            return
        }
        if !UserDefaults.standard.bool(forKey: "onboardingDone") { showOnboarding() }
    }

    /// Opening the app again (Spotlight, Finder) while it runs shows Settings, which is the way back
    /// if the menu-bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: - Windows

    func showOnboarding(fix: Bool = false) {
        onboardingWindow?.close()
        let w = Windows.make(fix ? "BetterAirdrop" : "Welcome to BetterAirdrop", size: NSSize(width: 620, height: 500), transparentTitle: true) {
            OnboardingView(model: model, fixMode: fix) { [weak self] backlog in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.notifications.clearLostAccess()
                if !backlog.isEmpty { self?.renameFiles(backlog) }
            }
        }
        onboardingWindow = w
        Windows.show(w)
    }

    func showHistory() {
        status.close()
        if historyWindow == nil {
            historyWindow = Windows.make("History", size: NSSize(width: 620, height: 460), resizable: true) {
                HistoryView(model: model, actions: self)
            }
        }
        Windows.show(historyWindow!)
    }

    func showSettings() {
        status.close()
    }

    // MARK: - Renaming files by hand

    func chooseFilesToRename() {
        status.close()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose photos to rename. You'll see the new names before anything changes."
        panel.prompt = "Preview Names"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.heic, .heif, .jpeg, .png, .rawImage]
        panel.directoryURL = model.folder
        panel.begin { [weak self] r in
            if r == .OK { self?.renameFiles(panel.urls) }
        }
    }

    /// The preview sheet for any set of files (Rename Files…, a drop on the icon, Services, backlog).
    func renameFiles(_ urls: [URL]) {
        status.close()
        let files = urls.filter { Planner.imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else { NSSound.beep(); return }
        let pm = RenamePreviewModel(files: files)
        let ref = WindowRef()
        let view = RenamePreviewView(m: pm, cancel: { ref.window?.close() }, commit: { [weak self] proposals in
            self?.model.commit(proposals) { batch in
                ref.window?.close()
                self?.notifications.post(batch)
            }
        })
        let window = Windows.make("Rename Photos", size: NSSize(width: 560, height: 200)) { view }
        (window.contentView as? NSHostingView<RenamePreviewView>)?.sizingOptions = [.preferredContentSize]
        ref.window = window
        renameWindows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.renameWindows.removeAll { $0 === n.object as? NSWindow } }
        }
        Windows.show(window)
        model.plan(files) { proposals in
            pm.rows = proposals.map { .init(proposal: $0, name: (($0.target ?? $0.source) as NSString).lastPathComponent) }
            pm.planning = false
        }
    }

    /// Finder → Services → Rename with BetterAirdrop (NSServices in Info.plist).
    @objc func renameFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        renameFiles(urls)
    }

    // MARK: - PanelActions

    func openFolder() {
        status.close()
        NSWorkspace.shared.open(model.folder)
    }

    func fixAccess() {
        status.close()
        showOnboarding(fix: true)
    }

    /// Undo from anywhere. An output edited since it was renamed asks first ("Undo Anyway").
    func undo(_ selection: Undoer.Selection) {
        model.undo(selection) { [weak self] outcomes, error in
            guard let self else { return }
            if let error { NSSound.beep(); NSLog("undo: \(error)"); return }
            let edited = outcomes.filter { $0.status == .refused && $0.reason == .editedSince }
            let restored = outcomes.filter { $0.status == .restored }.count
            if case .batch(let id) = selection, restored > 0 { self.notifications.postUndone(batch: id, restored: restored) }
            guard !edited.isEmpty else {
                if outcomes.contains(where: { $0.status == .failed }) { self.showFailures(outcomes) }
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = edited.count == 1
                ? "You've edited this photo since BetterAirdrop renamed it. Undo anyway?"
                : "You've edited \(edited.count) of these photos since BetterAirdrop renamed them. Undo anyway?"
            alert.informativeText = "Undoing brings back the original and removes the edited copy."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Undo Anyway")
            alert.buttons[1].hasDestructiveAction = true
            if alert.runModal() == .alertSecondButtonReturn {
                for o in edited { self.model.undo(.file(o.target), force: true) { _, _ in } }
            }
        }
    }

    func showFailures(_ outcomes: [Undoer.Outcome]) {
        let alert = NSAlert()
        alert.messageText = "Some files couldn't be put back"
        alert.informativeText = outcomes.filter { $0.status == .failed }.compactMap(\.message).joined(separator: "\n")
        alert.runModal()
    }

    /// From an "(offline)" banner: undo the batch, then name the originals again with Claude.
    func renameAgainWithClaude(_ batch: String) {
        model.undo(.batch(batch)) { [weak self] outcomes, _ in
            let sources = outcomes.filter { $0.status == .restored }.map { URL(fileURLWithPath: $0.source) }
                .filter { $0.pathExtension.lowercased() != "mov" }
            guard let self, !sources.isEmpty else { return }
            self.model.plan(sources, backend: "claude") { proposals in
                self.model.commit(proposals) { self.notifications.post($0) }
            }
        }
    }

    func reveal(_ paths: [String]) {
        status.close()
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func redo(_ item: RecentItem) { model.redo(item) }
    func quit() { NSApp.terminate(nil) }
}

final class WindowRef { weak var window: NSWindow? }

enum Headless {
    static func uninstall(purge: Bool) -> Int32 { 1 }
}
