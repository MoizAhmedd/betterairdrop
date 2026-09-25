import BetterAirdropCore
import Foundation

/// One row in the menu's Recent list: a renamed photo, newest first.
public struct RecentItem: Identifiable, Equatable, Sendable {
    public var id: String { batch + "\u{0}" + source }
    public var batch: String
    /// The original path (IMG_5301.HEIC).
    public var source: String
    /// The new path.
    public var target: String
    public var time: Date
    public var undone: Bool

    public var newName: String { (target as NSString).lastPathComponent }
    public var oldName: String { (source as NSString).lastPathComponent }
    /// The file that exists now: the new one, or the original after an undo.
    public var currentPath: String { undone ? source : target }

    /// "from IMG_5301.HEIC · 2 min ago", or "Put back · was 2026-…jpg" once undone.
    public func detail(now: Date = Date()) -> String {
        undone ? "Put back · was \(newName)" : "from \(oldName) · \(RelativeTime.string(time, now: now))"
    }
}

public enum Recent {
    /// The last `limit` photos (not Live Photo videos, not failures), newest first.
    public static func items(_ batches: [Journal.BatchSummary], limit: Int = 5) -> [RecentItem] {
        var out: [RecentItem] = []
        for b in batches {
            for e in b.entries.reversed() {
                guard e.state == .done || e.state == .undo,
                      (e.begin.source as NSString).pathExtension.lowercased() != "mov" else { continue }
                out.append(RecentItem(batch: b.id, source: e.latest.source, target: e.latest.target,
                                      time: Journal.date(e.latest.time) ?? b.time, undone: e.state == .undo))
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// The newest batch that still has something to undo: its ID and how many photos it holds.
    public static func lastUndoable(_ batches: [Journal.BatchSummary]) -> (id: String, count: Int)? {
        for b in batches {
            let n = b.undoable.filter { ($0.begin.source as NSString).pathExtension.lowercased() != "mov" }.count
            if n > 0 { return (b.id, n) }
        }
        return nil
    }
}
