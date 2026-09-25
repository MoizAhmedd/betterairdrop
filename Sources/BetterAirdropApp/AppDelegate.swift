import AppKit
import BetterAirdropCore
import BetterAirdropKit
import ServiceManagement
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
        if !UserDefaults.standard.bool(forKey: "onboardingDone") { firstRun() }
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

    func showSettings() { showSettings(pane: nil) }

    func showSettings(pane: SettingsWindow.Pane?) {
        status.close()
        if settingsWindow == nil { settingsWindow = SettingsWindow.make(model: model, app: self) }
        if let pane, let tabs = settingsWindow?.contentViewController as? NSTabViewController { tabs.selectedTabViewItemIndex = pane.rawValue }
        Windows.show(settingsWindow!)
    }

    /// Settings → Advanced → Uninstall… (the same sequence as `betterairdrop uninstall`).
    func uninstall(purge: Bool) {
        let steps = AppUninstall.uninstaller().uninstall(purge: purge)
        for s in steps { NSLog("uninstall: \(s.name) \(s.ok ? "ok" : "FAILED") \(s.detail ?? "")") }
        NSApp.terminate(nil)
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

    /// The preview sheet for any set of files (Rename Files…, a drop on the icon, Services, the
    /// first-run backlog). Names are worked out 20 at a time; nothing changes until Rename.
    func renameFiles(_ urls: [URL]) {
        status.close()
        let files = urls.filter { Planner.imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else { NSSound.beep(); return }
        let pm = RenamePreviewModel(files: files, claude: model.engine.name.hasPrefix("Claude"))
        let ref = WindowRef()
        let view = RenamePreviewView(m: pm, cancel: { ref.window?.close() }, more: { [weak self] in self?.planNext(pm) },
                                     commit: { [weak self] proposals in
            self?.model.commit(proposals) { batch in
                ref.window?.close()
                self?.notifications.post(batch)
                self?.model.scanBacklog()
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
        planNext(pm)
    }

    private func planNext(_ pm: RenamePreviewModel) {
        let batch = pm.nextBatch
        guard !batch.isEmpty else { return }
        pm.planning = true
        model.plan(batch) { proposals in
            pm.rows += proposals.map { .init(proposal: $0, name: (($0.target ?? $0.source) as NSString).lastPathComponent) }
            pm.planned += batch.count
            pm.planning = false
        }
    }

    /// "Found 12 unnamed photos in Downloads…" (menu) and the first-run banner's Preview.
    func previewBacklog() {
        guard !model.backlog.isEmpty else { return }
        renameFiles(model.backlog)
    }

    /// "Better names: add a Claude key".
    func addClaudeKey() { showSettings(pane: .naming) }

    // MARK: - First run (no wizard)

    /// Straight to the menu bar: ask for Downloads now (the one prompt), turn on launch at login,
    /// look for a key in the shell, and offer to preview photos already in Downloads. The
    /// notifications prompt waits for the first rename. The old wizard is in Settings → General.
    func firstRun() {
        let d = UserDefaults.standard
        d.set(true, forKey: "onboardingDone")
        Permissions.didAsk = true
        if !LoginItem.isEnabled { LoginItem.set(true) }
        model.refreshCredential { [weak self] in self?.model.lookForShellKey() }
        Permissions.probe(model.folder) { [weak self] ok in
            guard let self else { return }
            self.model.recheck()
            guard ok else { self.status.open(); return }
            self.model.scanBacklog { count in
                self.status.open()
                if count > 0 { self.notifications.postBacklog(count: count, folder: self.model.folderName) }
            }
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

/// The uninstall sequence with the app-only steps filled in.
enum AppUninstall {
    static func uninstaller() -> Uninstaller {
        var u = Uninstaller()
        u.cliLink = CLILink(target: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/betterairdrop"))
        u.unregisterLoginItem = {
            do { try SMAppService.mainApp.unregister(); return true } catch {
                let s = SMAppService.mainApp.status; return s == .notRegistered || s == .notFound   // nothing to remove is fine
            }
        }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            u.recycleApp = { (try? FileManager.default.trashItem(at: bundle, resultingItemURL: nil)) != nil }
        }
        return u
    }
}

/// `BetterAirdrop --uninstall [--purge]`: what `betterairdrop uninstall` runs, inside the app's own
/// identity so SMAppService can remove its login item.
enum Headless {
    static func uninstall(purge: Bool) -> Int32 {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.betterairdrop.app") where app.processIdentifier != me {
            app.terminate()
        }
        Thread.sleep(forTimeInterval: 1)
        let steps = AppUninstall.uninstaller().uninstall(purge: purge)
        for s in steps { print("\(s.ok ? "✓" : "✗") \(s.name)\(s.detail.map { ": \($0)" } ?? "")") }
        return steps.allSatisfy(\.ok) ? 0 : 1
    }
}
