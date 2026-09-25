@testable import BetterAirdropCore
import Foundation
import Testing

@Suite struct CredentialStoreTests {
    final class Dir {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-cred-\(UUID().uuidString)")
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func storesOnlyForTheUser() throws {
        let d = Dir()
        let store = CredentialStore(directory: d.url.appendingPathComponent("support"))
        #expect(store.readAPIKey() == nil)
        #expect(!store.hasAPIKey())
        try store.storeAPIKey(" sk-ant-one \n")
        #expect(store.readAPIKey() == "sk-ant-one")
        #expect(store.hasAPIKey())
        #expect(mode(store.file) == 0o600)
        #expect(mode(store.file.deletingLastPathComponent()) == 0o700)
        try store.storeAPIKey("sk-ant-two")
        #expect(store.readAPIKey() == "sk-ant-two")
        #expect(mode(store.file) == 0o600)
        #expect(store.deleteAPIKey())
        #expect(!store.deleteAPIKey())
        #expect(store.readAPIKey() == nil)
    }

    @Test func tightensLoosePermissions() throws {
        let d = Dir()
        let store = CredentialStore(directory: d.url)
        try store.storeAPIKey("sk-ant-x")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
        #expect(store.readAPIKey() == "sk-ant-x")
        #expect(mode(store.file) == 0o600)
    }

    @Test func ignoresGarbage() throws {
        let d = Dir()
        let store = CredentialStore(directory: d.url)
        try FileManager.default.createDirectory(at: d.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.file)
        #expect(store.readAPIKey() == nil)
    }

    @Test func migratesTheKeychainItemOnce() throws {
        let d = Dir()
        final class Legacy: @unchecked Sendable { var key: String? = "sk-ant-legacy"; var reads = 0; var deletes = 0 }
        let legacy = Legacy()
        var store = CredentialStore(directory: d.url)
        store.legacy = .init(exists: { legacy.key != nil },
                             read: { legacy.reads += 1; return legacy.key },
                             delete: { legacy.deletes += 1; legacy.key = nil; return true })
        #expect(store.readAPIKey() == "sk-ant-legacy")
        #expect(legacy.key == nil && legacy.deletes == 1)
        #expect(store.readAPIKey() == "sk-ant-legacy")
        #expect(legacy.reads == 1, "the Keychain is read once, ever")
    }

    @Test func migrationNeverOverwritesAStoredKey() throws {
        let d = Dir()
        final class Legacy: @unchecked Sendable { var reads = 0; var deletes = 0 }
        let legacy = Legacy()
        var store = CredentialStore(directory: d.url)
        store.legacy = .init(exists: { true }, read: { legacy.reads += 1; return "sk-ant-old" }, delete: { legacy.deletes += 1; return true })
        try store.storeAPIKey("sk-ant-new")
        #expect(store.readAPIKey() == "sk-ant-new")
        #expect(legacy.reads == 0)
        #expect(legacy.deletes == 1, "the stale Keychain item is still removed")
    }

    @Test func noLegacyItemMeansNoKeychainRead() {
        let d = Dir()
        var store = CredentialStore(directory: d.url)
        final class Reads: @unchecked Sendable { var n = 0 }
        let reads = Reads()
        store.legacy = .init(exists: { false }, read: { reads.n += 1; return nil }, delete: { false })
        #expect(store.readAPIKey() == nil)
        #expect(reads.n == 0)
    }
}
