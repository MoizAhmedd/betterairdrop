import Foundation

/// The Anthropic API key stored by `betterairdrop auth claude` or the app, in
/// `~/Library/Application Support/betterairdrop/credentials` (0600, in a 0700 folder), the way the
/// `ant` CLI keeps its tokens.
///
/// Not the Keychain: a Keychain item's access list names the app's code signature, and the M7 spike
/// (docs/spikes.md §f) showed a self-signed update still gets a Keychain prompt, so every release
/// would ask again. A key saved by an older build is moved here once and the Keychain item deleted.
public struct CredentialStore: Sendable {
    /// The pre-0.3 Keychain item, injectable for tests.
    public struct Legacy: Sendable {
        public var exists: @Sendable () -> Bool
        public var read: @Sendable () -> String?
        public var delete: @Sendable () -> Bool
        public init(exists: @escaping @Sendable () -> Bool, read: @escaping @Sendable () -> String?, delete: @escaping @Sendable () -> Bool) {
            self.exists = exists; self.read = read; self.delete = delete
        }
        public static let keychain = Legacy(exists: { Keychain.hasAPIKey() }, read: { Keychain.readAPIKey() },
                                            delete: { Keychain.deleteAPIKey() })
        public static let none = Legacy(exists: { false }, read: { nil }, delete: { false })
    }

    public let directory: URL
    public var legacy: Legacy
    public var file: URL { directory.appendingPathComponent("credentials") }
    var migratedMarker: URL { directory.appendingPathComponent(".keychain-migrated") }

    public init(directory: URL = Paths.supportDirectory, legacy: Legacy = .keychain) {
        self.directory = directory
        self.legacy = legacy
    }

    private struct Contents: Codable { var anthropic_api_key: String }

    public func readAPIKey() -> String? {
        migrateOnce()
        return readFile()
    }

    /// No Keychain access and no migration: just whether the file holds a key.
    public func hasAPIKey() -> Bool { readFile() != nil }

    public func storeAPIKey(_ key: String) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(Contents(anthropic_api_key: k))
        // Written 0600 from the start (never briefly readable by others), then moved into place.
        let tmp = directory.appendingPathComponent(".credentials-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        guard rename(tmp.path, file.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
    }

    @discardableResult
    public func deleteAPIKey() -> Bool {
        (try? FileManager.default.removeItem(at: file)) != nil
    }

    private func readFile() -> String? {
        guard let data = FileManager.default.contents(atPath: file.path),
              let c = try? JSONDecoder().decode(Contents.self, from: data) else { return nil }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue, mode & 0o077 != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let k = c.anthropic_api_key.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    /// Moves a pre-0.3 Keychain key into the file, once. Checking the item's existence doesn't read
    /// the secret, so there's no Keychain prompt unless a key is actually there to move.
    private func migrateOnce() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: migratedMarker.path), legacy.exists() else { return }
        if readFile() == nil, let old = legacy.read() {
            guard (try? storeAPIKey(old)) != nil else { return }
        }
        _ = legacy.delete()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: migratedMarker.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
}
