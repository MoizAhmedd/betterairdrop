import BetterAirdropCore
import Foundation

/// The one mention of Pro the app ever makes on its own: a single row in the menu, the first time
/// it opens after the 20th successful rename, and never again.
public enum ProMention {
    public static let threshold = 20

    public static func shouldShow(renames: Int, isPro: Bool, alreadyShown: Bool) -> Bool {
        !isPro && !alreadyShown && renames >= threshold
    }
}

/// Which folders the app watches, and for what. The AirDrop folder always comes first and keeps
/// its own rule; Pro adds the screenshot folder and any folders the user picked. A folder is
/// only ever watched once, so two watchers never race for the same file.
public struct WatchPlan: Equatable, Sendable {
    public enum Role: String, Sendable { case airdrop, screenshots, folder }

    public struct Entry: Equatable, Sendable {
        public var folder: URL
        public var intake: Watcher.Options.Intake
        public var role: Role
        /// Pro, "Name PDFs too": PDFs here are named as well. Never in the screenshot folder.
        public var pdfs = false
        /// Live Photo videos are only picked up in the AirDrop folder.
        public var movies: Bool { role == .airdrop }
    }

    public var entries: [Entry]

    /// - Parameters:
    ///   - screenshots: the screenshot folder when "Also name new screenshots" is on (and Pro is unlocked).
    ///   - extras: the user's other folders (when Pro is unlocked).
    ///   - pdfs: "Name PDFs too" is on and Pro is unlocked: the AirDrop folder and the other folders
    ///     name new PDFs as well.
    public static func make(main: URL, mainAirdropOnly: Bool, screenshots: URL?, extras: [URL], pdfs: Bool = false) -> WatchPlan {
        var mainEntry = Entry(folder: main, intake: mainAirdropOnly ? .airdrop : .all, role: .airdrop, pdfs: pdfs)
        var seen: Set<String> = [key(main)]
        var others: [Entry] = []
        for u in extras where seen.insert(key(u)).inserted {
            others.append(Entry(folder: u, intake: .all, role: .folder, pdfs: pdfs))
        }
        if let s = screenshots {
            if key(s) == key(main) {
                if mainEntry.intake == .airdrop { mainEntry.intake = .airdropAndScreenshots }
            } else if seen.insert(key(s)).inserted {
                others.insert(Entry(folder: s, intake: .screenshots, role: .screenshots), at: 0)
            }
            // else: an added folder is the screenshot folder; it names every new image there already.
        }
        return WatchPlan(entries: [mainEntry] + others)
    }

    /// Paths compare case-insensitively (APFS's default) and without a trailing slash.
    public static func key(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }
}

/// "Rename any photos" for whole folders (Pro): a dropped folder, or Finder → Services on one,
/// becomes the photos inside it. Packages (a Photos library, an app) are never opened, so their
/// insides can't be renamed by accident.
public enum PhotoFolders {
    public static let limit = 5_000

    public static func isFolder(_ u: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func isPackage(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// Images (and, with `pdfs`, PDFs) in the folder and its subfolders, skipping hidden files and
    /// packages, sorted by path, at most `limit`.
    public static func images(in folder: URL, limit: Int = PhotoFolders.limit, pdfs: Bool = false) -> [URL] {
        guard isFolder(folder), !isPackage(folder),
              let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            if isPackage(u) { e.skipDescendants(); continue }
            guard Planner.imageExtensions.contains(u.pathExtension.lowercased()) || (pdfs && PDFIntake.isPDF(u)),
                  (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out.append(u)
            if out.count >= limit { break }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Splits what was dropped into image files (plus PDFs, with `pdfs`) and folders. Free renames
    /// the files; Pro expands the folders too. `skippedPDFs` counts PDFs left out because `pdfs` is off.
    public static func split(_ urls: [URL], pdfs: Bool = false) -> (files: [URL], folders: [URL], skippedPDFs: Int) {
        var files: [URL] = [], folders: [URL] = [], skipped = 0
        for u in urls {
            if isFolder(u) { if !isPackage(u) { folders.append(u) } }
            else if Planner.imageExtensions.contains(u.pathExtension.lowercased()) { files.append(u) }
            else if PDFIntake.isPDF(u) { if pdfs { files.append(u) } else { skipped += 1 } }
        }
        return (files, folders, skipped)
    }
}

/// The Pro name builder (Settings → Naming): the parts of a name in order, a separator and a date
/// format, turned into an ordinary template like `{date}_{place}_{subject}`.
public struct NameBuilder: Equatable, Sendable {
    public enum Part: String, CaseIterable, Sendable {
        case date, city, description, kind

        public var token: String {
            switch self {
            case .date: "date"
            case .city: "place"
            case .description: "subject"
            case .kind: "kind"
            }
        }

        public var title: String {
            switch self {
            case .date: "Date"
            case .city: "City"
            case .description: "Description"
            case .kind: "Kind"
            }
        }
    }

    public enum Separator: String, CaseIterable, Sendable {
        case underscore = "_", hyphen = "-", space = " "

        public var title: String {
            switch self {
            case .underscore: "_  underscore"
            case .hyphen: "-  hyphen"
            case .space: "space"
            }
        }
    }

    /// The parts that are on, in order. Description is always on (a name needs it).
    public private(set) var parts: [Part]
    public var separator: Separator

    public static let standard = NameBuilder(parts: [.date, .city, .description], separator: .underscore)

    public init(parts: [Part], separator: Separator) {
        var p: [Part] = []
        for x in parts where !p.contains(x) { p.append(x) }
        if !p.contains(.description) { p.append(.description) }
        self.parts = p
        self.separator = separator
    }

    /// Reads a template the builder could have made; nil for anything else (a hand-written one).
    public init?(template: String) {
        for sep in Separator.allCases {
            let pieces = template.components(separatedBy: sep.rawValue)
            let parts = pieces.compactMap { piece in Part.allCases.first { "{\($0.token)}" == piece } }
            guard parts.count == pieces.count, Set(parts).count == parts.count, parts.contains(.description) else { continue }
            self.init(parts: parts, separator: sep)
            return
        }
        return nil
    }

    public var template: String { parts.map { "{\($0.token)}" }.joined(separator: separator.rawValue) }

    /// Every part, the ones in use first (in order), then the rest.
    public var rows: [(part: Part, on: Bool)] {
        parts.map { ($0, true) } + Part.allCases.filter { !parts.contains($0) }.map { ($0, false) }
    }

    public func isOn(_ p: Part) -> Bool { parts.contains(p) }

    /// Turns a part on (added at the end) or off. Description can't be turned off.
    public mutating func toggle(_ p: Part) {
        if let i = parts.firstIndex(of: p) {
            if p != .description { parts.remove(at: i) }
        } else {
            parts.append(p)
        }
    }

    /// Moves a part that's on earlier (negative) or later (positive), stopping at either end.
    public mutating func move(_ p: Part, by delta: Int) {
        guard let i = parts.firstIndex(of: p) else { return }
        parts.remove(at: i)
        parts.insert(p, at: min(max(i + delta, 0), parts.count))
    }
}
