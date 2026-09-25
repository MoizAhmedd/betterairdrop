import Foundation

/// The project was called airname until September 2026. On first use, move the old config and state
/// folders to their new names so settings and undo history carry over. Runs at most once per process,
/// and never overwrites anything that already exists under the new name.
public enum LegacyMigration {
    static let once: Void = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        move(support.appendingPathComponent("airname"), to: Paths.defaultSupportDirectory)
        move(Config.configBase.appendingPathComponent("airname"), to: Config.configBase.appendingPathComponent("betterairdrop"))
    }()

    /// Renames `old` to `new` if `old` exists and `new` doesn't. Returns true if it moved something.
    @discardableResult
    public static func move(_ old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? fm.moveItem(at: old, to: new)) != nil
    }
}
