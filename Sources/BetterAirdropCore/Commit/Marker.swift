import Foundation

/// `dev.betterairdrop.done` xattr on every file betterairdrop produced, so it is never processed twice.
public struct Marker: Codable, Sendable, Equatable {
    public static let name = "dev.betterairdrop.done"
    /// Written by releases from before the rename (when the project was called airname). Still honoured.
    public static let legacyName = "dev.airname.done"
    public var v = 1
    public var batch: String
    /// SHA-1 of the source file this output was made from.
    public var sourceSHA1: String

    public init(batch: String, sourceSHA1: String) { self.batch = batch; self.sourceSHA1 = sourceSHA1 }

    public static func read(_ url: URL) -> Marker? {
        guard let d = Xattr.get(url, name) ?? Xattr.get(url, legacyName) else { return nil }
        return (try? JSONDecoder().decode(Marker.self, from: d)) ?? Marker(batch: "?", sourceSHA1: "?")
    }

    public func write(_ url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        try Xattr.set(url, Self.name, try enc.encode(self))
    }

    public static func remove(_ url: URL) { Xattr.remove(url, name); Xattr.remove(url, legacyName) }

    /// Set by undo on the restored original, so a watcher doesn't rename it straight back (its
    /// arrival time, quarantine or inode change, is after the watcher started). Renaming by hand
    /// ignores it.
    public static let undoneName = "dev.betterairdrop.undone"
    public static func markUndone(_ url: URL) { try? Xattr.set(url, undoneName, Data("1".utf8)) }
    public static func isUndone(_ url: URL) -> Bool { Xattr.get(url, undoneName) != nil }
}
