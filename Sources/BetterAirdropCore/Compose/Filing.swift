import Foundation

/// Auto-file by kind (Pro, menu-bar app): a destination folder per kind, optionally with a
/// `YYYY-MM` subfolder from the photo's date, e.g. receipts → ~/Documents/Receipts/2026-10/.
/// The move is the rename itself (the Committer's target is in another folder), so it's journaled
/// and undone like any rename. Kinds without a rule, and destinations on another volume, stay where they arrived.
public struct Filing: Sendable, Equatable {
    public var folders: [Kind: URL]
    public var monthly: Bool

    public init(folders: [Kind: URL], monthly: Bool = true) {
        self.folders = folders
        self.monthly = monthly
    }

    /// From the config's `[file]` table (`file.receipt = "~/Documents/Receipts"`); nil when no kind has a folder.
    public init?(config: Config, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        var folders: [Kind: URL] = [:]
        for (k, path) in config.fileFolders {
            guard let kind = Kind(rawValue: k), !path.isEmpty else { continue }
            let expanded = path == "~" ? home.path : path.hasPrefix("~/") ? home.path + path.dropFirst(1) : path
            guard expanded.hasPrefix("/") else { continue }
            folders[kind] = URL(fileURLWithPath: expanded).standardizedFileURL
        }
        guard !folders.isEmpty else { return nil }
        self.init(folders: folders, monthly: config.fileMonthly)
    }

    /// Where a photo of `kind` taken on `date` (`YYYY-MM-DD`) goes, or nil to leave it in place.
    /// Without a capture date the month is `now`'s.
    public func directory(for kind: Kind, date: String?, now: Date = Date()) -> URL? {
        guard let base = folders[kind] else { return nil }
        guard monthly else { return base }
        return base.appendingPathComponent(Self.month(date, now: now), isDirectory: true)
    }

    /// Whether `dir` (or, while it doesn't exist yet, its nearest existing parent) is on the same
    /// volume as `source`. Filing is an atomic rename, which can't cross volumes, so a file whose
    /// destination is on another disk is renamed where it arrived instead.
    public static func sameVolume(_ dir: URL, as source: URL) -> Bool {
        func device(_ u: URL) -> dev_t? {
            var st = stat()
            return stat(u.path, &st) == 0 ? st.st_dev : nil
        }
        var d = dir.standardizedFileURL
        while device(d) == nil, d.path != "/" { d = d.deletingLastPathComponent() }
        return device(d) == device(source)
    }

    static func month(_ date: String?, now: Date) -> String {
        if let d = date, d.count >= 7, d.range(of: #"^\d{4}-\d{2}"#, options: .regularExpression) != nil {
            return String(d.prefix(7))
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: now)
    }
}
