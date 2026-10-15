import AppKit
import BetterAirdropCore
import SwiftUI

/// The sequence of surfaces `BETTERAIRDROP_SNAPSHOT_DIR` renders.
extension AppDelegate {
    func runSnapshots() {
        func onboarding(_ name: String, fix: Bool = false, _ setup: @escaping (OnboardingState) -> Void) -> [(String, () -> Void)] {
            [(name, {
                let st = OnboardingState(fixMode: fix)
                st.presetForSnapshot = true
                setup(st)
                self.onboardingWindow?.close()
                let w = Windows.make("Welcome to BetterAirdrop", size: NSSize(width: 620, height: 500), transparentTitle: true) {
                    OnboardingView(model: self.model, state: st) {}
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
        steps += onboarding("onboarding-1-granted") { $0.step = 0; $0.access = .granted }
        steps += onboarding("onboarding-1-denied") { $0.step = 0; $0.access = .denied }
        steps += onboarding("onboarding-2-engine") { $0.step = 1; $0.engine = .claude; $0.verify = .failed("Anthropic didn't accept this key. Check that you copied all of it.") }
        steps += onboarding("onboarding-fix-denied", fix: true) { $0.access = .denied }
        steps += [
            ("rename", { self.renameFiles(Snapshot.sampleFiles(self.model.folder)) }),
            ("rename-wait", {}),
            ("rename-capture", { Snapshot.capture(self.renameWindows.last, "rename-preview"); self.renameWindows.last?.close() }),
            ("history", { self.showHistory() }),
            ("history-capture", { Snapshot.capture(self.historyWindow, "history"); self.historyWindow?.close() }),
            ("undo-one", { if let i = self.model.recent.first(where: { !$0.undone }) { self.undo(.file(i.target)) } }),
            ("pause", { self.model.pause(.oneHour) }),
            ("panel-2", { self.status.open() }),
            ("panel-2-capture", { Snapshot.capture(self.status.panelWindow, "panel-undone-paused"); self.status.close(); self.model.resume() }),
            ("settings", { self.showSettings() }),
        ]
        for (i, name) in ["general", "naming", "advanced", "about"].enumerated() {
            steps += [
                ("tab-\(name)", { (self.settingsWindow?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = i }),
                ("tab-\(name)-capture", { Snapshot.capture(self.settingsWindow, "settings-\(name)") }),
            ]
        }
        steps += [
            // Notifications turned off in System Settings while the config still has them on.
            ("notify-off-tab", { (self.settingsWindow?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = 0 }),
            // After the tab's own refresh, which reads the real (not determined) permission.
            ("notify-off", { self.model.updateConfig { $0.watchNotify = true }; self.model.notificationStatus = .denied }),
            ("notify-off-capture", { Snapshot.capture(self.settingsWindow, "settings-general-notifications-off") }),
            ("settings-close", { self.settingsWindow?.close() }),
            // Lost access: make the (test) folder unreadable for a moment.
            ("lock", { guard !self.model.folderIsDownloads else { return }; try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: self.model.folder.path); self.model.recheck() }),
            ("panel-3", { self.status.open() }),
            ("panel-3-capture", {
                Snapshot.capture(self.status.panelWindow, "panel-lost-access"); self.status.close()
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.model.folder.path)
            }),
        ]
        Snapshot.run(steps)
    }

}
