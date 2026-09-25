import Foundation
import Sparkle

/// Sparkle 2. The appcast URL (SUFeedURL) and EdDSA public key (SUPublicEDKey) are filled in by the
/// release pipeline (M12). Until then they're empty, the updater isn't started, and "Check for
/// Updates" explains that this build doesn't update itself.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController?

    static var feedURL: String { (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? "" }
    static var publicKey: String { (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? "" }
    static var isConfigured: Bool {
        !feedURL.isEmpty && !publicKey.isEmpty && !feedURL.hasPrefix("__")
    }

    init() {
        controller = Self.isConfigured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }
}
