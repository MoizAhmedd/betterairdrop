import Foundation

/// The `betterairdrop` command in Terminal: a symlink at ~/.local/bin/betterairdrop pointing at the
/// copy inside the app (Contents/Helpers/betterairdrop). No password needed.
public struct CLILink: Sendable {
    public enum Status: Equatable, Sendable {
        case notInstalled
        /// Our link, pointing at this app's CLI.
        case installed
        /// Our link, but pointing at another copy of the app (or a missing one).
        case stale(String)
        /// Something else is at that path; we never touch it.
        case foreign
    }

    public var link: URL
    public var target: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, target: URL) {
        link = home.appendingPathComponent(".local/bin/betterairdrop")
        self.target = target
    }

    public var status: Status {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
            return fm.fileExists(atPath: link.path) ? .foreign : .notInstalled
        }
        if dest == target.path { return .installed }
        return Self.isOurs(dest) ? .stale(dest) : .foreign
    }

    /// A link into some BetterAirdrop.app's Helpers folder.
    static func isOurs(_ dest: String) -> Bool {
        dest.hasSuffix(".app/Contents/Helpers/betterairdrop")
    }

    public func install() throws {
        switch status {
        case .installed: return
        case .foreign: throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: link.path])
        case .stale: try FileManager.default.removeItem(at: link)
        case .notInstalled: break
        }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    }

    /// Removes the link only if it's ours. Returns true if something was removed.
    @discardableResult
    public func remove() -> Bool {
        switch status {
        case .installed, .stale: return (try? FileManager.default.removeItem(at: link)) != nil
        case .notInstalled, .foreign: return false
        }
    }

    /// Whether ~/.local/bin is on this PATH (to tell the user to add it if not).
    public func onPath(_ path: String? = ProcessInfo.processInfo.environment["PATH"]) -> Bool {
        (path ?? "").split(separator: ":").contains { $0 == link.deletingLastPathComponent().path }
    }
}
