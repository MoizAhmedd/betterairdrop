import AppKit
import BetterAirdropCore
import BetterAirdropKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, PanelActions {
    let model = AppModel()
    let updater = Updater()
    var status: StatusItemController!
    var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        status = StatusItemController(model: model, actions: self)
        model.start()
        if Snapshot.directory != nil {
            if ProcessInfo.processInfo.environment["BETTERAIRDROP_SNAPSHOT_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            runSnapshots()
            return
        }
        if !UserDefaults.standard.bool(forKey: "onboardingDone") { showOnboarding() }
    }

    func runSnapshots() {
        func onboarding(_ name: String, _ setup: @escaping (OnboardingState) -> Void) -> [(String, () -> Void)] {
            [(name, {
                let st = OnboardingState(fixMode: false)
                st.presetForSnapshot = true
                setup(st)
                self.onboardingWindow?.close()
                let w = Windows.make("Welcome to BetterAirdrop", size: NSSize(width: 620, height: 500), transparentTitle: true) {
                    OnboardingView(model: self.model, state: st) { _ in }
                }
                self.onboardingWindow = w
                Windows.show(w)
            }), (name + "-capture", { Snapshot.capture(self.onboardingWindow, name) })]
        }
        var steps: [(String, () -> Void)] = [
            ("panel", { self.status.open() }),
            ("panel-capture", { Snapshot.capture(self.status.panelWindow, "panel"); Snapshot.saveGlyphs() }),
            ("close", { self.status.close() }),
        ]
        steps += onboarding("onboarding-1-welcome") { $0.step = 0 }
        steps += onboarding("onboarding-2-access") { $0.step = 1 }
        steps += onboarding("onboarding-2-denied") { $0.step = 1; $0.access = .denied }
        steps += onboarding("onboarding-3-engine") { $0.step = 2; $0.engine = .claude; $0.verify = .failed("Anthropic didn't accept this key. Check that you copied all of it.") }
        steps += onboarding("onboarding-4-background") { $0.step = 3; $0.backlogFiles = [URL(fileURLWithPath: "/x.heic")] }
        steps += onboarding("onboarding-5-done") { $0.step = 4; $0.access = .granted }
        steps += extraSnapshots()
        Snapshot.run(steps)
    }

    func extraSnapshots() -> [(String, () -> Void)] { [] }

    /// Opening the app again (Spotlight, Finder) while it runs shows Settings, which is the way back
    /// if the menu-bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: - PanelActions

    func renameFiles(_ urls: [URL]) { status.close() }
    func chooseFilesToRename() { status.close() }
    func openFolder() {
        status.close()
        NSWorkspace.shared.open(model.folder)
    }
    func showHistory() { status.close() }
    func showSettings() { status.close() }
    func fixAccess() {
        status.close()
        showOnboarding(fix: true)
    }

    func showOnboarding(fix: Bool = false) {
        onboardingWindow?.close()
        let w = Windows.make("Welcome to BetterAirdrop", size: NSSize(width: 620, height: 500), transparentTitle: true) {
            OnboardingView(model: model, fixMode: fix) { [weak self] backlog in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                if !backlog.isEmpty { self?.renameFiles(backlog) }
            }
        }
        onboardingWindow = w
        Windows.show(w)
    }

    func undo(_ selection: Undoer.Selection) {
        model.undo(selection) { _, _ in }
    }

    func reveal(_ paths: [String]) {
        status.close()
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func redo(_ item: RecentItem) { model.redo(item) }
    func quit() { NSApp.terminate(nil) }
}

enum Headless {
    static func uninstall(purge: Bool) -> Int32 { 1 }
}
