import AppKit
import BetterAirdropCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// "Open BetterAirdrop at login". The state is always read from SMAppService, never stored (so
/// it can't disagree with System Settings → General → Login Items).
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns an error message, or nil on success.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        if ProcessInfo.processInfo.environment["BETTERAIRDROP_NO_LOGIN_ITEM"] == "1" { return nil }  // tests, snapshots
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Folder permission: probing, the Privacy deep link and the Open-panel fallback.
@MainActor
enum Permissions {
    /// Probing Downloads the first time shows the system prompt. We only probe after the user asked
    /// for it once (onboarding "Allow Access…"), so the prompt always has a reason on screen.
    static var didAsk: Bool {
        get { UserDefaults.standard.bool(forKey: "askedForFolderAccess") }
        set { UserDefaults.standard.set(newValue, forKey: "askedForFolderAccess") }
    }

    /// Lists the folder off the main thread (a prompt blocks the calling thread until answered).
    static func probe(_ folder: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = FolderAccess.canList(folder)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        NSWorkspace.shared.open(url)
    }

    /// The user-intent route: choosing the folder in an Open panel grants access too.
    static func chooseFolder(_ folder: URL, completion: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Choose your \(folder.lastPathComponent) folder so BetterAirdrop can rename AirDrops there."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.begin { r in
            guard r == .OK else { completion(false); return }
            probe(folder, completion: completion)
        }
    }
}

/// Notification permission. Asked only when the user turns notifications on.
@MainActor
enum NotificationPermission {
    static func current(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let st = s.authorizationStatus
            DispatchQueue.main.async { completion(st) }
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
}

/// Plain AppKit windows hosting SwiftUI. Settings, onboarding and history use these rather than
/// SwiftUI scenes, which are unreliable in a menu-bar-only app.
@MainActor
enum Windows {
    static func make<V: View>(_ title: String, size: NSSize, transparentTitle: Bool = false, resizable: Bool = false,
                              @ViewBuilder content: () -> V) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        if transparentTitle { style.insert(.fullSizeContentView) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        if transparentTitle {
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
        }
        w.contentView = NSHostingView(rootView: content())
        w.setContentSize(size)
        w.center()
        return w
    }

    static func show(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

extension View {
    /// The mockups' grouped rows: white rounded box with hairline separators.
    func groupBox() -> some View {
        background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.75)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.09), lineWidth: 0.5))
    }
}
