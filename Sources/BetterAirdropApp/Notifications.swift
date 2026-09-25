import AppKit
import BetterAirdropCore
import BetterAirdropKit
import UserNotifications

/// One banner per batch (UX mockup d), posted by the app so it carries its own name and icon.
/// Hovering shows Undo and Show in Finder; clicking the banner reveals the files.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    enum Category {
        static let batch = "betterairdrop.batch"
        static let offline = "betterairdrop.batch.offline"
        static let lost = "betterairdrop.lost"
    }
    enum Action {
        static let undo = "undo", reveal = "reveal", renameAgain = "renameAgain", fix = "fix", pause = "pause"
    }

    weak var app: AppDelegate?
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    init(app: AppDelegate) {
        self.app = app
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.batch, actions: [
                UNNotificationAction(identifier: Action.undo, title: "Undo"),
                UNNotificationAction(identifier: Action.reveal, title: "Show in Finder"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.offline, actions: [
                UNNotificationAction(identifier: Action.undo, title: "Undo"),
                UNNotificationAction(identifier: Action.renameAgain, title: "Rename Again with Claude"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.lost, actions: [
                UNNotificationAction(identifier: Action.fix, title: "Fix…", options: [.foreground]),
                UNNotificationAction(identifier: Action.pause, title: "Pause BetterAirdrop"),
            ], intentIdentifiers: []),
        ])
    }

    var enabled: Bool { app?.model.config.watchNotify ?? false }

    func post(_ batch: Watcher.Batch) {
        guard enabled else { return }
        let m = BatchMessage.make(batch)
        let content = UNMutableNotificationContent()
        content.title = m.title
        content.body = m.body
        content.categoryIdentifier = m.offline ? Category.offline : Category.batch
        content.userInfo = ["batch": batch.id,
                            "paths": batch.outcomes.compactMap { $0.status == .done ? $0.target : nil }]
        // The thumbnail is a small copy: the system moves the attachment file into its own store.
        if let p = m.thumbnailPath, let copy = Thumbnails.notificationCopy(of: p),
           let a = try? UNNotificationAttachment(identifier: "thumb", url: copy) {
            content.attachments = [a]
        }
        center.add(UNNotificationRequest(identifier: batch.id, content: content, trigger: nil))
    }

    /// Replaces the batch's banner with "Undone".
    func postUndone(batch: String, restored: Int) {
        guard enabled else { return }
        let m = BatchMessage.undone(restored: restored)
        let content = UNMutableNotificationContent()
        content.title = m.title
        content.body = m.body
        center.removeDeliveredNotifications(withIdentifiers: [batch])
        center.add(UNNotificationRequest(identifier: batch, content: content, trigger: nil))
    }

    /// One banner when access goes missing (never one per file).
    func postLostAccess() {
        let m = BatchMessage.lostAccess
        let content = UNMutableNotificationContent()
        content.title = m.title.replacingOccurrences(of: "Downloads", with: app?.model.folderName ?? "Downloads")
        content.body = m.body
        content.categoryIdentifier = Category.lost
        center.add(UNNotificationRequest(identifier: "lost-access", content: content, trigger: nil))
    }

    func clearLostAccess() { center.removeDeliveredNotifications(withIdentifiers: ["lost-access"]) }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let info = r.notification.request.content.userInfo
        let batch = info["batch"] as? String
        let paths = info["paths"] as? [String] ?? []
        let action = r.actionIdentifier
        let category = r.notification.request.content.categoryIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let app = self?.app else { return }
            switch action {
            case Action.undo: if let batch { app.undo(.batch(batch)) }
            case Action.renameAgain: if let batch { app.renameAgainWithClaude(batch) }
            case Action.fix: app.fixAccess()
            case Action.pause: app.model.pause(.indefinitely)
            case UNNotificationDefaultActionIdentifier:
                if category == Category.lost { app.fixAccess() } else { app.reveal(paths) }
            case Action.reveal: app.reveal(paths)
            default: break
            }
        }
        done()
    }
}
