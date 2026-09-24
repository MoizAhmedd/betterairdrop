import Foundation

/// `dev.airname.done` xattr on every file airname produced, so it is never processed twice.
public struct Marker: Codable, Sendable, Equatable {
    public static let name = "dev.airname.done"
    public var v = 1
    public var batch: String
    /// SHA-1 of the source file this output was made from.
    public var sourceSHA1: String

    public init(batch: String, sourceSHA1: String) { self.batch = batch; self.sourceSHA1 = sourceSHA1 }

    public static func read(_ url: URL) -> Marker? {
        guard let d = Xattr.get(url, name) else { return nil }
        return (try? JSONDecoder().decode(Marker.self, from: d)) ?? Marker(batch: "?", sourceSHA1: "?")
    }

    public func write(_ url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        try Xattr.set(url, Self.name, try enc.encode(self))
    }

    public static func remove(_ url: URL) { Xattr.remove(url, name) }
}
