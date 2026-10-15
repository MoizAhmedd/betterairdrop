import BetterAirdropCore
import Foundation

/// This Mac's Pro license: the key, Polar's activation for this Mac, and what Polar last said.
public struct License: Codable, Equatable, Sendable {
    public var key: String
    /// Polar's ID for this Mac's activation (one of the key's 3).
    public var activationID: String
    /// The Mac's name, as shown in Polar's customer portal.
    public var label: String
    /// Polar's masked form of the key (`****-ABCD`), safe to show.
    public var displayKey: String?
    public var activatedAt: Date
    /// When Polar was last asked (whatever the answer), so it's asked at most weekly.
    public var lastCheckedAt: Date?
    /// When Polar last said the key is good.
    public var lastValidatedAt: Date?
    /// The first time Polar said the key is revoked or invalid, since it last said it was good.
    public var invalidSince: Date?
    public var invalidReason: String?

    enum CodingKeys: String, CodingKey {
        case key, label
        case activationID = "activation_id", displayKey = "display_key", activatedAt = "activated_at"
        case lastCheckedAt = "last_checked_at", lastValidatedAt = "last_validated_at"
        case invalidSince = "invalid_since", invalidReason = "invalid_reason"
    }

    public init(key: String, activationID: String, label: String, displayKey: String? = nil, activatedAt: Date) {
        self.key = key; self.activationID = activationID; self.label = label
        self.displayKey = displayKey; self.activatedAt = activatedAt
        self.lastCheckedAt = activatedAt; self.lastValidatedAt = activatedAt
    }

    /// What to show for the key: Polar's masked form, else the last four characters.
    public var maskedKey: String { displayKey ?? "…" + key.suffix(4) }
}

/// Whether Pro is unlocked. Pro stays on when Polar can't be reached or answers with an error;
/// only an explicit "revoked/invalid" answer starts the 14-day grace period, and only after it
/// ends is Pro locked. A later "valid" answer (or activating again) unlocks it.
public enum ProStatus: Equatable, Sendable {
    case free
    case active
    /// Polar said the key is no longer valid; Pro stays on until `until`.
    case grace(until: Date)
    /// The grace period is over.
    case lapsed

    public var isUnlocked: Bool {
        switch self {
        case .active, .grace: true
        case .free, .lapsed: false
        }
    }
}

public enum ProGate {
    public static let gracePeriod: TimeInterval = 14 * 86_400
    public static let revalidationInterval: TimeInterval = 7 * 86_400

    public static func status(_ license: License?, now: Date = Date()) -> ProStatus {
        guard let license else { return .free }
        guard let since = license.invalidSince else { return .active }
        let until = since.addingTimeInterval(gracePeriod)
        return now < until ? .grace(until: until) : .lapsed
    }

    /// At most once a week (and never for a clock that moved backwards by more than a day).
    public static func needsRevalidation(_ license: License, now: Date = Date()) -> Bool {
        guard let last = license.lastCheckedAt else { return true }
        let age = now.timeIntervalSince(last)
        return age >= revalidationInterval || age < -86_400
    }
}

/// `~/Library/Application Support/betterairdrop/license`: JSON, mode 0600 in a 0700 folder, next to
/// the Claude key (`CredentialStore`) and for the same reasons (no Keychain prompts on updates).
public struct LicenseStore: Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("license") }

    public init(directory: URL = Paths.supportDirectory) { self.directory = directory }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func read() -> License? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return try? Self.decoder.decode(License.self, from: data)
    }

    public func write(_ license: License) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try Self.encoder.encode(license)
        // Written 0600 from the start, then moved into place (as CredentialStore does).
        let tmp = directory.appendingPathComponent(".license-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        guard rename(tmp.path, file.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
    }

    @discardableResult
    public func delete() -> Bool { (try? FileManager.default.removeItem(at: file)) != nil }
}

extension License {
    /// What `license activate` prints: the confirmation, then `EngineStatus.hostedNotice` when the
    /// engine (worked out with this license) is now hosted naming.
    public func activatedMessage(engine: EngineStatus) -> String {
        let done = "BetterAirdrop Pro is active on “\(label)” (key \(maskedKey))."
        return engine.isHosted ? done + "\n" + EngineStatus.hostedNotice : done
    }
}

/// Hosted naming's key: only while Pro is active or in its grace period.
extension LicenseStore: LicenseKeySource {
    public func licenseKey() -> String? { read().flatMap { ProGate.status($0).isUnlocked ? $0.key : nil } }
}
