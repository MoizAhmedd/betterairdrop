import Foundation

/// Reverses changes recorded in the journal. Checks the output's SHA-1 first and refuses if the
/// file was edited since (unless forced). Also resolves `begin` records left by a crash.
public struct Undoer {
    public enum Selection: Sendable, Equatable {
        case last
        case batch(String)
        case file(String)
    }

    public struct Outcome: Codable, Sendable {
        public enum Status: String, Codable, Sendable { case restored, alreadyClean, refused, failed }
        /// Why a change was refused, so the app can offer "Undo Anyway" for the right case.
        public enum Reason: String, Codable, Sendable { case editedSince }
        public var source: String
        public var target: String
        public var status: Status
        public var message: String?
        public var reason: Reason?
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case nothingToUndo(String)
        public var description: String { switch self { case .nothingToUndo(let s): s } }
    }

    public let journal: Journal
    public let trasher: any Trasher
    public var force = false

    public init(journal: Journal = Journal(), trasher: any Trasher = Trash.default()) {
        self.journal = journal; self.trasher = trasher
    }

    /// Entries that can still be undone (committed or interrupted, not yet undone or rolled back).
    public func pending() -> [Journal.Entry] {
        journal.entries().filter { $0.state == .done || $0.state == .begin }
    }

    public func select(_ s: Selection) throws -> [Journal.Entry] {
        let open = pending()
        switch s {
        case .last:
            guard let batch = open.last?.begin.batch else { throw Error.nothingToUndo("nothing to undo") }
            return open.filter { $0.begin.batch == batch }
        case .batch(let id):
            let e = open.filter { $0.begin.batch == id }
            if e.isEmpty { throw Error.nothingToUndo("no undoable changes in batch \(id)") }
            return e
        case .file(let path):
            let p = URL(fileURLWithPath: path).standardizedFileURL.path
            let e = open.filter { $0.latest.target == p || $0.begin.source == p }.suffix(1)
            if e.isEmpty { throw Error.nothingToUndo("no undoable change for \(path)") }
            return Array(e)
        }
    }

    public func undo(_ s: Selection) throws -> [Outcome] {
        try select(s).reversed().map(undoEntry)
    }

    func undoEntry(_ e: Journal.Entry) -> Outcome {
        let r = e.latest
        let source = URL(fileURLWithPath: r.source), target = URL(fileURLWithPath: r.target)
        func outcome(_ st: Outcome.Status, _ msg: String? = nil, reason: Outcome.Reason? = nil) -> Outcome {
            if st == .restored || st == .alreadyClean { try? journal.append(r.with(.undo, message: msg)) }
            return Outcome(source: r.source, target: r.target, status: st, message: msg, reason: reason)
        }
        let targetExists = FileOps.exists(target)
        if targetExists && !force {
            guard let h = try? FileOps.sha1(target), h == r.outputSHA1 else {
                return outcome(.refused, "\(target.lastPathComponent) was changed after BetterAirdrop wrote it; use --force to undo anyway", reason: .editedSince)
            }
        }
        do {
            switch r.action {
            case .rename:
                if FileOps.exists(source) {
                    return outcome(.alreadyClean, "original is already in place")
                }
                guard targetExists else { return outcome(.failed, "neither \(source.lastPathComponent) nor \(target.lastPathComponent) exists") }
                try FileOps.renameExclusive(target, source)
                Marker.remove(source)
                return outcome(.restored)

            case .convert:
                Marker.remove(source)   // set when originals = "keep"
                if FileOps.exists(source) && !targetExists { return outcome(.alreadyClean, "original is already in place") }
                if !FileOps.exists(source) {
                    // The original went to the Trash (or was deleted). Bring it back first.
                    let trashed = r.trashed.map { URL(fileURLWithPath: $0) }.flatMap { FileOps.exists($0) ? $0 : nil }
                        ?? trasher.find(originalName: source.lastPathComponent, sha1: r.sourceSHA1)
                    guard let trashed else {
                        let why = r.originals == "delete" ? "the original was deleted (originals = \"delete\")" : "the original isn't in the Trash any more"
                        return outcome(.failed, "can't restore \(source.lastPathComponent): \(why); \(target.lastPathComponent) was left in place")
                    }
                    try FileOps.renameExclusive(trashed, source)
                }
                if targetExists { try FileManager.default.removeItem(at: target) }
                return outcome(.restored)

            case .skip:
                return outcome(.alreadyClean)
            }
        } catch {
            return outcome(.failed, "\(error)")
        }
    }
}
