import BetterAirdropCore
import BetterAirdropKit
import Foundation
import ServiceManagement
import UserNotifications

/// Keeps `app-state.json` current: the permissions only this app can see (macOS grants them per
/// app), for `betterairdrop status --json` and the agents that read it.
extension AppModel {
    /// Re-reads the notification permission (and, with `probe`, folder access, but only once
    /// the first run has asked for it, so this never shows a prompt of its own), then writes the file.
    func reportState(probe: Bool = false) {
        let folder = self.folder
        NotificationPermission.current { [weak self] status in
            guard let self else { return }
            self.notificationStatus = AppState.Notifications(status)
            guard probe && Permissions.didAsk else { self.writeAppState(); return }
            Permissions.probe(folder) { [weak self] ok in
                self?.folderAccess = ok
                self?.writeAppState()
            }
        }
    }

    func writeAppState() {
        let s = AppState(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                         folder: folderDisplayPath,
                         folderAccess: folderAccess.map { $0 ? .granted : .denied } ?? .waiting,
                         notifications: notificationStatus ?? .notAsked,
                         loginItem: AppState.LoginItem(SMAppService.mainApp.status),
                         watch: reportedWatch)
        DispatchQueue.global(qos: .utility).async { try? s.save() }
    }

    private var reportedWatch: AppState.Watch {
        if isPaused { return .paused }
        switch state {
        case .watching: return .watching
        case .paused: return .paused
        case .noAccess: return .noAccess
        case .lockedByOther: return .standingBy
        case .stopped: return .starting
        }
    }
}

extension AppState.Notifications {
    init(_ s: UNAuthorizationStatus) {
        switch s {
        case .authorized, .provisional, .ephemeral: self = .allowed
        case .denied: self = .denied
        default: self = .notAsked
        }
    }
}

extension AppState.LoginItem {
    init(_ s: SMAppService.Status) {
        switch s {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        default: self = .disabled
        }
    }
}
