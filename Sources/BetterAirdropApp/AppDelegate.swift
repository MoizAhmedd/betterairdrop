import AppKit
import BetterAirdropCore
import BetterAirdropKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, PanelActions {
    let model = AppModel()
    let updater = Updater()
    var status: StatusItemController!

    func applicationDidFinishLaunching(_ note: Notification) {
        status = StatusItemController(model: model, actions: self)
        model.start()
        if Snapshot.directory != nil { runSnapshots() }
    }

    func runSnapshots() {
        Snapshot.run([
            ("panel", { self.status.open() }),
            ("panel-capture", { Snapshot.capture(self.status.panelWindow, "panel"); Snapshot.saveGlyphs() }),
            ("close", { self.status.close() }),
        ])
    }

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
    func fixAccess() { status.close() }

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
