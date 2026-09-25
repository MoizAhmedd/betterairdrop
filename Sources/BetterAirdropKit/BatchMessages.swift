import BetterAirdropCore
import Foundation

/// Text for the one notification a batch gets (UX mockup d).
public struct BatchMessage: Equatable, Sendable {
    public var title: String
    public var body: String
    /// Claude was tried and failed for at least one photo, so Apple Vision named it.
    public var offline: Bool
    /// The first renamed photo (for the thumbnail).
    public var thumbnailPath: String?

    public init(title: String, body: String, offline: Bool = false, thumbnailPath: String? = nil) {
        self.title = title; self.body = body; self.offline = offline; self.thumbnailPath = thumbnailPath
    }

    public static func make(_ batch: Watcher.Batch) -> BatchMessage {
        let done = batch.outcomes.filter { $0.status == .done && !isMovie($0.source) }
        let proposals = Dictionary(batch.proposals.map { ($0.source, $0) }, uniquingKeysWith: { a, _ in a })
        let offline = done.contains { proposals[$0.source]?.suggestion?.fallbackFrom != nil }
        let n = done.count
        let f = batch.failed
        var title = n == 0 && f > 0 ? "Couldn't rename \(f) photo\(f == 1 ? "" : "s")" : "Renamed \(n) photo\(n == 1 ? "" : "s")"
        if n > 0 && f > 0 { title += ", \(f) failed" }
        if offline { title += " (offline)" }

        let names = done.compactMap { o -> String? in
            guard let t = o.target else { return nil }
            return n == 1 ? (t as NSString).lastPathComponent : shortName(t, proposal: proposals[o.source])
        }
        var body: String
        switch names.count {
        case 0: body = batch.outcomes.first { $0.status == .failed }?.message ?? ""
        case 1: body = names[0]
        case 2: body = "\(names[0]) and \(names[1])"
        default: body = "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
        if offline { body = "Claude couldn't be reached, so Apple Vision named \(n == 1 ? "it" : "these"): " + body }
        return BatchMessage(title: title, body: body, offline: offline, thumbnailPath: done.first?.target)
    }

    /// After Undo, the banner is replaced by this.
    public static func undone(restored: Int) -> BatchMessage {
        BatchMessage(title: "Undone", body: "Put back \(restored) original\(restored == 1 ? "" : "s") with \(restored == 1 ? "its" : "their") old name\(restored == 1 ? "" : "s").")
    }

    public static let lostAccess = BatchMessage(
        title: "BetterAirdrop can't read Downloads",
        body: "New AirDrops aren't being renamed. Click to fix it (about 10 seconds).")

    /// The subject part of a name ("walnut-lamp-on-oak-sideboard.jpg"), so several fit in a banner.
    static func shortName(_ path: String, proposal: Proposal?) -> String {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        if let subject = proposal?.tokens?["subject"], !subject.isEmpty,
           file.range(of: subject) != nil {
            return ext.isEmpty ? subject : "\(subject).\(ext)"
        }
        return file
    }

    static func isMovie(_ p: String) -> Bool { (p as NSString).pathExtension.lowercased() == "mov" }
}
