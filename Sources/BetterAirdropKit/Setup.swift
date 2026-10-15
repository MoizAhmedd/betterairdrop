import BetterAirdropCore
import Foundation

/// Written by `betterairdrop setup`, so the app's first launch knows the choices were already made
/// (by a script or an AI agent) and only asks macOS for what a person has to grant.
public struct SetupRecord: Codable, Equatable, Sendable {
    public var schema = 1
    public var completedAt: Date
    /// nil = not chosen; the app's first run turns launch at login on, as it does without setup.
    public var launchAtLogin: Bool?

    public init(completedAt: Date = Date(), launchAtLogin: Bool? = nil) {
        self.completedAt = completedAt
        self.launchAtLogin = launchAtLogin
    }

    enum CodingKeys: String, CodingKey {
        case schema, completedAt = "completed_at", launchAtLogin = "launch_at_login"
    }

    public static var defaultURL: URL { Paths.supportDirectory.appendingPathComponent("setup.json") }

    public static func load(from url: URL = defaultURL) -> SetupRecord? {
        guard let d = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONCoding.decoder.decode(SetupRecord.self, from: d)
    }

    public func save(to url: URL = defaultURL) throws {
        try JSONCoding.write(self, to: url)
    }
}

/// What `betterairdrop setup` was asked to do. nil = leave as it is.
public struct SetupRequest: Equatable, Sendable {
    public var engine: String?
    /// The name of an environment variable that holds the Anthropic API key.
    public var apiKeyEnv: String?
    /// A key read from standard input.
    public var apiKeyFromStdin: String?
    public var launchAtLogin: Bool?
    public var notify: Bool?

    public init(engine: String? = nil, apiKeyEnv: String? = nil, apiKeyFromStdin: String? = nil,
                launchAtLogin: Bool? = nil, notify: Bool? = nil) {
        self.engine = engine; self.apiKeyEnv = apiKeyEnv; self.apiKeyFromStdin = apiKeyFromStdin
        self.launchAtLogin = launchAtLogin; self.notify = notify
    }
}

/// What setup knows about this Mac before changing anything.
public struct SetupContext: Sendable {
    public var config: Config
    public var environment: [String: String]
    /// A key is stored in the credentials file.
    public var storedKey: Bool
    /// The Anthropic CLI (`ant`) is logged in.
    public var antLoggedIn: Bool
    /// nil = Apple Intelligence can name photos; otherwise why it can't.
    public var appleUnavailable: String?

    public init(config: Config, environment: [String: String], storedKey: Bool, antLoggedIn: Bool, appleUnavailable: String?) {
        self.config = config; self.environment = environment; self.storedKey = storedKey
        self.antLoggedIn = antLoggedIn; self.appleUnavailable = appleUnavailable
    }
}

public struct SetupError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// The changes `setup` will make, worked out without touching anything.
public struct SetupPlan: Equatable {
    public var config: Config
    /// The key to store (never printed).
    public var keyToStore: String?
    public var launchAtLogin: Bool?
    /// One line per change, for the confirmation and the log ("Naming engine: auto → vision").
    public var changes: [String]
    /// Things worth knowing that don't stop setup.
    public var notes: [String]

    public static let engines = EngineChoice.allCases.map(\.rawValue)   // auto, apple, claude, vision

    public static func make(_ r: SetupRequest, _ c: SetupContext) throws -> SetupPlan {
        var config = c.config
        var changes: [String] = []
        var notes: [String] = []

        // The key: from an environment variable or stdin, never from an argument (shell history, ps).
        if r.apiKeyEnv != nil && r.apiKeyFromStdin != nil {
            throw SetupError("pass --api-key-env or --api-key-stdin, not both")
        }
        var key: String?
        if let name = r.apiKeyEnv {
            guard let v = c.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                throw SetupError("$\(name) isn't set in this shell")
            }
            key = v
        } else if let s = r.apiKeyFromStdin {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty else { throw SetupError("no key on standard input") }
            key = v
        }
        if let k = key {
            guard k.hasPrefix("sk-ant-"), !k.contains(where: \.isWhitespace) else {
                throw SetupError("that doesn't look like an Anthropic API key (they start with sk-ant-)")
            }
            changes.append("Claude key: store \(r.apiKeyEnv.map { "$\($0)" } ?? "the key from stdin") (…\(k.suffix(4)))")
        }

        // The app is opened from Finder or `open`, so it never sees this shell's environment: only a
        // stored key or an `ant` login count.
        let appHasCredential = key != nil || c.storedKey || c.antLoggedIn
        let envKeyName = "ANTHROPIC_API_KEY"
        let envKeyHint = r.apiKeyEnv == nil && !(c.environment[envKeyName] ?? "").isEmpty
            ? " $\(envKeyName) is set in this shell; add --api-key-env \(envKeyName) to store it for the app." : ""

        if let e = r.engine {
            guard let choice = EngineChoice(rawValue: e) else {
                throw SetupError("--engine must be one of \(engines.joined(separator: ", "))")
            }
            switch choice {
            case .claude where !appHasCredential:
                throw SetupError("--engine claude needs a Claude key the app can use."
                                 + (envKeyHint.isEmpty ? " Add --api-key-env VAR or --api-key-stdin, or log in with `ant auth login`." : envKeyHint))
            case .apple where c.appleUnavailable != nil:
                throw SetupError("Apple Intelligence can't name photos on this Mac (\(c.appleUnavailable!)). "
                                 + "Use --engine auto: it switches to Apple Intelligence once it's ready.")
            default: break
            }
            if config.backend != e { changes.append("Naming engine: \(config.backend) → \(e)") }
            config.backend = e
        }
        if config.backend == "auto" && !appHasCredential && c.appleUnavailable != nil {
            notes.append("Photos will be named with Apple Vision (on this Mac) until a Claude key is stored." + envKeyHint)
        }

        if let n = r.notify, n != config.watchNotify {
            changes.append("Notifications after each batch: \(n ? "on" : "off")")
            config.watchNotify = n
        }
        if let l = r.launchAtLogin { changes.append("Open at login: \(l ? "on" : "off")") }
        return SetupPlan(config: config, keyToStore: key, launchAtLogin: r.launchAtLogin, changes: changes, notes: notes)
    }
}

/// What the app does at its first launch. Without `setup` it's the zero-wizard first run (ask for
/// Downloads, turn on launch at login, look for a key in the login shell). After `setup`, the
/// choices are already made: no shell lookup, launch at login as chosen, and notifications are
/// asked for right after Downloads, while the person the agent told is at the Mac.
public struct FirstRunPlan: Equatable, Sendable {
    public var headless: Bool
    public var lookForShellKey: Bool
    public var registerLoginItem: Bool
    public var askNotificationsAfterAccess: Bool

    /// nil when the first run has already happened.
    public static func make(onboardingDone: Bool, setup: SetupRecord?, notify: Bool) -> FirstRunPlan? {
        guard !onboardingDone else { return nil }
        guard let setup else {
            return FirstRunPlan(headless: false, lookForShellKey: true, registerLoginItem: true, askNotificationsAfterAccess: false)
        }
        return FirstRunPlan(headless: true, lookForShellKey: false, registerLoginItem: setup.launchAtLogin ?? true,
                            askNotificationsAfterAccess: notify)
    }
}

/// Snake-case JSON with ISO 8601 dates, written atomically.
enum JSONCoding {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
