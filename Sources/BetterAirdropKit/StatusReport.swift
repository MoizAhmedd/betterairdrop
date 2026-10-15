import BetterAirdropCore
import Darwin
import Foundation
import notify

/// What only the running app can know (macOS grants permissions per app, so the CLI in a Terminal
/// can't check them), written to `app-state.json` whenever it changes. `betterairdrop status --json`
/// reads it.
public struct AppState: Codable, Equatable, Sendable {
    public enum Access: String, Codable, Sendable { case granted, denied, waiting }
    public enum Notifications: String, Codable, Sendable { case allowed, denied, notAsked = "not_asked" }
    public enum LoginItem: String, Codable, Sendable { case enabled, requiresApproval = "requires_approval", disabled }
    public enum Watch: String, Codable, Sendable { case watching, paused, noAccess = "no_access", standingBy = "standing_by", starting }

    public var schema = 1
    public var version: String
    public var pid: Int32
    public var updatedAt: Date
    public var folder: String
    /// The watched folder (Downloads unless changed). `waiting` = macOS is still asking, or not checked yet.
    public var folderAccess: Access
    public var notifications: Notifications
    public var loginItem: LoginItem
    public var watch: Watch
    /// What hosted naming last heard from the server in the app (names left, the last error). Nil
    /// until the app has used it.
    public var hosted: HostedUsage?

    public init(version: String, pid: Int32 = getpid(), updatedAt: Date = Date(), folder: String, folderAccess: Access,
                notifications: Notifications, loginItem: LoginItem, watch: Watch, hosted: HostedUsage? = nil) {
        self.version = version; self.pid = pid; self.updatedAt = updatedAt; self.folder = folder
        self.folderAccess = folderAccess; self.notifications = notifications; self.loginItem = loginItem; self.watch = watch
        self.hosted = hosted
    }

    enum CodingKeys: String, CodingKey {
        case schema, version, pid, folder, notifications, watch, hosted
        case updatedAt = "updated_at", folderAccess = "folder_access", loginItem = "login_item"
    }

    public static var defaultURL: URL { Paths.supportDirectory.appendingPathComponent("app-state.json") }

    public static func load(from url: URL = defaultURL) -> AppState? {
        guard let d = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONCoding.decoder.decode(AppState.self, from: d)
    }

    public func save(to url: URL = defaultURL) throws { try JSONCoding.write(self, to: url) }
}

/// Darwin notifications between the CLI and the app (no permissions needed, nothing on disk).
public enum AppSignal: String, Sendable {
    /// `setup` changed the config or the key: reload them.
    case reload = "dev.betterairdrop.reload"
    /// `status` wants a fresh `app-state.json`.
    case report = "dev.betterairdrop.report"

    public func post() { notify_post(rawValue) }

    /// Calls `handler` on the main queue each time the signal is posted. Returns the registration
    /// token; the app keeps it for its lifetime.
    public func observe(_ handler: @escaping @MainActor @Sendable () -> Void) -> Int32 {
        var token: Int32 = 0
        notify_register_dispatch(rawValue, &token, .main) { _ in MainActor.assumeIsolated { handler() } }
        return token
    }
}

/// `betterairdrop status --json`. Field names are a public contract: add, don't rename.
public struct StatusReport: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public var installed: Bool
        public var path: String?
        public var version: String?
        public var running: Bool
    }
    public struct Setup: Codable, Equatable, Sendable {
        /// `betterairdrop setup` has run on this Mac.
        public var done: Bool
        public var completedAt: Date?
        enum CodingKeys: String, CodingKey { case done, completedAt = "completed_at" }
    }
    public struct Engine: Codable, Equatable, Sendable {
        /// The configured backend (auto, claude, vision, apple).
        public var backend: String
        /// What names the next photo, e.g. "Claude Haiku 4.5" or "Apple Vision".
        public var active: String
        public var detail: String?
    }
    public struct Credential: Codable, Equatable, Sendable {
        /// A credential the app can use (a stored key or an `ant` login; the app never sees shell variables).
        public var present: Bool
        /// "stored", "ant" or nil.
        public var source: String?
    }
    /// BetterAirdrop Pro on this Mac (`betterairdrop license` manages it).
    public struct LicenseInfo: Codable, Equatable, Sendable {
        /// none, active, grace (Polar said the key is invalid; Pro stays on until `grace_until`), invalid (Pro is off).
        public var state: String
        /// Pro features are unlocked.
        public var pro: Bool
        /// The masked key, e.g. "****-ABCD".
        public var key: String?
        public var graceUntil: Date?
        enum CodingKeys: String, CodingKey { case state, pro, key, graceUntil = "grace_until" }

        public static let none = LicenseInfo(state: "none", pro: false)

        public init(state: String, pro: Bool, key: String? = nil, graceUntil: Date? = nil) {
            self.state = state; self.pro = pro; self.key = key; self.graceUntil = graceUntil
        }

        public init(_ license: License?, now: Date = Date()) {
            switch ProGate.status(license, now: now) {
            case .free: self = .none
            case .active: self.init(state: "active", pro: true, key: license?.maskedKey)
            case .grace(let until): self.init(state: "grace", pro: true, key: license?.maskedKey, graceUntil: until)
            case .lapsed: self.init(state: "invalid", pro: false, key: license?.maskedKey)
            }
        }
    }
    /// Hosted naming (Pro: Claude with no API key). `remaining`, `resets_at` and `last_error` are what
    /// the app last heard from the server (null until it has used it, and after the month resets).
    public struct HostedInfo: Codable, Equatable, Sendable {
        /// Pro is active or in grace, so hosted naming can be used.
        public var available: Bool
        public var remaining: Int?
        public var resetsAt: Date?
        public var lastError: String?
        enum CodingKeys: String, CodingKey { case available, remaining, resetsAt = "resets_at", lastError = "last_error" }

        public static let none = HostedInfo(available: false)

        public init(available: Bool, remaining: Int? = nil, resetsAt: Date? = nil, lastError: String? = nil) {
            self.available = available; self.remaining = remaining; self.resetsAt = resetsAt; self.lastError = lastError
        }

        // Always written, null included, so agents can rely on the keys.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(available, forKey: .available)
            try c.encode(remaining, forKey: .remaining)
            try c.encode(resetsAt, forKey: .resetsAt)
            try c.encode(lastError, forKey: .lastError)
        }
    }
    public struct Credentials: Codable, Equatable, Sendable {
        public var claude: Credential
        public var license = LicenseInfo.none
        public var hosted = HostedInfo.none
    }
    public struct Permissions: Codable, Equatable, Sendable {
        /// granted, denied, waiting, or unknown (the app hasn't reported yet).
        public var folderAccess: String
        /// allowed, denied, not_asked or unknown.
        public var notifications: String
        /// enabled, requires_approval, disabled or unknown.
        public var loginItem: String
        /// When the app last reported these.
        public var reportedAt: Date?
        enum CodingKeys: String, CodingKey {
            case notifications, folderAccess = "folder_access", loginItem = "login_item", reportedAt = "reported_at"
        }
    }
    public struct Watching: Codable, Equatable, Sendable {
        /// watching, paused, no_access, standing_by, starting, not_running, or unknown (an app too old to report).
        public var state: String
        public var folder: String
        /// "app", "cli" or nil.
        public var by: String?
    }
    public struct Step: Codable, Equatable, Sendable {
        /// "human" (only a person can do it) or "agent" (a command can).
        public var who: String
        /// false = optional.
        public var required: Bool
        public var text: String
        /// A command that does it, or opens the right System Settings pane.
        public var command: String?
    }

    public var schema = 1
    /// True when AirDrops are being renamed right now.
    public var ready: Bool
    public var cliVersion: String
    public var app: App
    public var setup: Setup
    public var engine: Engine
    public var credentials: Credentials
    public var permissions: Permissions
    public var watching: Watching
    public var nextSteps: [Step]

    enum CodingKeys: String, CodingKey {
        case schema, ready, app, setup, engine, credentials, permissions, watching
        case cliVersion = "cli_version", nextSteps = "next_steps"
    }

    public func json() throws -> String { String(decoding: try JSONCoding.encoder.encode(self), as: UTF8.self) }
}

extension StatusReport {
    /// Everything `status` gathered, before it's put together.
    public struct Inputs: Sendable {
        public var cliVersion: String
        public var appPath: String?
        public var appVersion: String?
        public var appRunning: Bool
        /// The app's last report (nil if it never ran, or is too old to write one).
        public var appState: AppState?
        public var setup: SetupRecord?
        public var config: Config
        public var storedKey: Bool
        public var antLoggedIn: Bool
        /// Who holds the watch lock.
        public var lockHolder: ProcessLock.Owner?
        /// Apple Intelligence can name photos (then `auto` uses it).
        public var appleReady: Bool
        /// The stored Pro license, if any.
        public var license: License?
        public var now: Date

        public init(cliVersion: String, appPath: String?, appVersion: String?, appRunning: Bool, appState: AppState?,
                    setup: SetupRecord?, config: Config, storedKey: Bool, antLoggedIn: Bool, lockHolder: ProcessLock.Owner?, appleReady: Bool = false,
                    license: License? = nil, now: Date = Date()) {
            self.cliVersion = cliVersion; self.appPath = appPath; self.appVersion = appVersion; self.appRunning = appRunning
            self.appState = appState; self.setup = setup; self.config = config; self.storedKey = storedKey
            self.antLoggedIn = antLoggedIn; self.lockHolder = lockHolder; self.appleReady = appleReady
            self.license = license; self.now = now
        }
    }

    public static let privacyFilesPane = "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders'"
    public static let notificationsPane = "open 'x-apple.systempreferences:com.apple.Notifications-Settings.extension'"
    public static let loginItemsPane = "open 'x-apple.systempreferences:com.apple.LoginItems-Settings.extension'"

    public static func make(_ i: Inputs) -> StatusReport {
        let hasCredential = i.storedKey || i.antLoggedIn
        let pro = ProGate.status(i.license, now: i.now).isUnlocked
        let usage = i.appState?.hosted?.current(now: i.now)
        let engine = EngineStatus.current(config: i.config, hasCredential: hasCredential, appleReady: i.appleReady,
                                          hasLicense: pro, hostedRemaining: usage?.remaining)
        let state = i.appRunning ? i.appState : nil
        let folderName = Self.folderName(i.appState?.folder ?? i.config.watchFolder)

        let watching: Watching
        switch i.lockHolder?.kind {
        case .cli:
            watching = Watching(state: "watching", folder: tilde(i.lockHolder!.folder), by: "cli")
        case .app where state == nil:
            watching = Watching(state: "watching", folder: tilde(i.lockHolder!.folder), by: "app")   // an app too old to report
        default:
            if let state {
                watching = Watching(state: state.watch.rawValue, folder: state.folder, by: state.watch == .watching ? "app" : nil)
            } else if i.appRunning {
                watching = Watching(state: "unknown", folder: i.config.watchFolder, by: nil)   // too old to report
            } else {
                watching = Watching(state: "not_running", folder: i.config.watchFolder, by: nil)
            }
        }

        let permissions = Permissions(folderAccess: i.appState?.folderAccess.rawValue ?? "unknown",
                                      notifications: i.appState?.notifications.rawValue ?? "unknown",
                                      loginItem: i.appState?.loginItem.rawValue ?? "unknown",
                                      reportedAt: i.appState?.updatedAt)

        var steps: [Step] = []
        if i.appPath == nil {
            steps.append(Step(who: "agent", required: true, text: "Install the app.",
                              command: "curl -fsSL https://betterairdrop.com/install | sh"))
        } else if !i.appRunning {
            steps.append(Step(who: "agent", required: true, text: "Open the app.", command: "open '\(i.appPath!)'"))
        }
        if i.appRunning, let s = state {
            switch s.folderAccess {
            case .waiting:
                steps.append(Step(who: "human", required: true,
                                  text: "Click Allow when macOS asks “BetterAirdrop would like to access files in your \(folderName) folder”."))
            case .denied:
                steps.append(Step(who: "human", required: true,
                                  text: "Turn on BetterAirdrop in System Settings → Privacy & Security → Files & Folders → \(folderName).",
                                  command: privacyFilesPane))
            case .granted: break
            }
            if i.config.watchNotify {
                switch s.notifications {
                case .notAsked where i.setup != nil && s.folderAccess != .denied:
                    steps.append(Step(who: "human", required: false,
                                      text: "Click Allow when macOS asks to let BetterAirdrop send notifications (banners with Undo)."))
                case .denied:
                    steps.append(Step(who: "human", required: false,
                                      text: "For banners with Undo, turn on BetterAirdrop in System Settings → Notifications.",
                                      command: notificationsPane))
                default: break
                }
            }
            if s.loginItem == .requiresApproval {
                steps.append(Step(who: "human", required: false,
                                  text: "Allow BetterAirdrop in System Settings → General → Login Items, so it starts at login.",
                                  command: loginItemsPane))
            }
            if s.watch == .paused {
                steps.append(Step(who: "human", required: true, text: "Resume from the BetterAirdrop menu-bar icon (it's paused)."))
            }
        }
        if let h = i.lockHolder, h.kind == .cli {
            steps.append(Step(who: "agent", required: false,
                              text: "`betterairdrop watch` (pid \(h.pid)) is watching instead of the app. Stop it to let the app take over."))
        }
        if engine.name == "Apple Vision" && i.config.backend != "vision" && !hasCredential {
            steps.append(Step(who: "agent", required: false, text: "For better names, store a Claude key.",
                              command: "betterairdrop setup --api-key-env ANTHROPIC_API_KEY --yes"))
        }

        // Pro is never suggested here; only a key Polar has rejected gets a (optional) step.
        let license = LicenseInfo(i.license, now: i.now)
        if license.state == "grace" || license.state == "invalid" {
            let f = DateFormatter()
            f.dateStyle = .medium
            let when = license.graceUntil.map { "Pro stays on until \(f.string(from: $0))" } ?? "Pro is off"
            steps.append(Step(who: "human", required: false,
                              text: "Polar says the Pro key \(license.key ?? "") is no longer valid (\(when)). Activate a valid key.",
                              command: "betterairdrop license activate <key>"))
        }

        let source: String? = i.storedKey ? "stored" : i.antLoggedIn ? "ant" : nil
        return StatusReport(
            ready: watching.state == "watching",
            cliVersion: i.cliVersion,
            app: App(installed: i.appPath != nil, path: i.appPath, version: i.appVersion, running: i.appRunning),
            setup: Setup(done: i.setup != nil, completedAt: i.setup?.completedAt),
            engine: Engine(backend: i.config.backend, active: engine.name, detail: engine.detail),
            credentials: Credentials(claude: Credential(present: hasCredential, source: source), license: license,
                                     hosted: HostedInfo(available: pro, remaining: usage?.remaining, resetsAt: usage?.resetsAt,
                                                        lastError: usage?.lastError)),
            permissions: permissions,
            watching: watching,
            nextSteps: steps)
    }

    /// `/Users/me/Downloads` → `~/Downloads`, the way the config writes it.
    public static func tilde(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func folderName(_ path: String) -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return FolderAccess.isDownloads(url) ? "Downloads" : url.lastPathComponent
    }
}
