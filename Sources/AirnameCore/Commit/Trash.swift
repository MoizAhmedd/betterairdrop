import Foundation

/// Moves originals out of the way in a way `undo` can reverse.
public protocol Trasher: Sendable {
    /// Moves the file to the Trash and returns where it ended up.
    func trash(_ url: URL) throws -> URL
    /// Looks for a trashed copy of `originalName` with the given SHA-1 (crash recovery,
    /// when the trashed location was never journaled).
    func find(originalName: String, sha1: String) -> URL?
}

/// The user's Trash, via `FileManager.trashItem` (Finder's "Put Back" works too).
public struct SystemTrash: Trasher {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let r = result as URL? else { throw CocoaError(.fileNoSuchFile) }
        return r
    }

    public func find(originalName: String, sha1: String) -> URL? {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return DirectoryTrash.search(trash, originalName: originalName, sha1: sha1)
    }
}

/// A plain folder standing in for the Trash (tests, and `AIRNAME_TRASH_DIR` for dry-runs on real data).
public struct DirectoryTrash: Trasher {
    public let directory: URL
    public init(_ directory: URL) { self.directory = directory }

    public func trash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 1
        while true {
            let name = n == 1 ? url.lastPathComponent : "\(stem) \(n).\(ext)"
            let dest = directory.appendingPathComponent(name)
            do { try FileOps.renameExclusive(url, dest); return dest }
            catch let e as POSIXError where e.code == .EEXIST { n += 1 }
        }
    }

    public func find(originalName: String, sha1: String) -> URL? {
        Self.search(directory, originalName: originalName, sha1: sha1)
    }

    static func search(_ dir: URL, originalName: String, sha1: String) -> URL? {
        let stem = (originalName as NSString).deletingPathExtension.lowercased()
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return items.first { u in
            u.lastPathComponent.lowercased().hasPrefix(stem) && (try? FileOps.sha1(u)) == sha1
        }
    }
}

public enum Trash {
    /// `AIRNAME_TRASH_DIR` swaps the real Trash for a folder.
    public static func `default`() -> any Trasher {
        if let p = ProcessInfo.processInfo.environment["AIRNAME_TRASH_DIR"] { return DirectoryTrash(URL(fileURLWithPath: p)) }
        return SystemTrash()
    }
}
