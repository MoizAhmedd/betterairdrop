import Foundation

/// Applies proposals safely. Order for each file (PLAN.md §2 "Compose + Commit"):
///
///   1. convert: write the JPEG to a hidden temp file in the same folder and fsync it
///   2. journal `begin` (fsynced)
///   3. move into place with RENAME_EXCL (never overwrites; a clash picks the next `-N`)
///   4. set the `dev.betterairdrop.done` marker
///   5. original → Trash (or keep with a marker / delete, per config), journal `done` with the Trash location
///
/// A failure rolls back and journals `error`, leaving the source untouched. A crash at any point
/// leaves either the original in place or a `begin` record that `undo` can resolve.
public final class Committer {
    public enum Stage: String, CaseIterable, Sendable {
        case tempWritten, journaledBegin, movedIntoPlace, marked, originalHandled
    }

    /// Thrown by a fault hook to simulate the process dying: no rollback runs.
    public struct SimulatedCrash: Error {}

    public struct Outcome: Codable, Sendable {
        public enum Status: String, Codable, Sendable { case done, skipped, failed }
        public var source: String
        public var target: String?
        public var status: Status
        public var trashed: String?
        public var message: String?
        /// Planning and commit times (the watcher adds settle, quiet and total).
        public var timings: StageTimings?
    }

    public let config: Config
    public let journal: Journal
    public let trasher: any Trasher
    public var backend = "none"
    /// Test hook, called after each stage.
    public var fault: ((Stage, URL) throws -> Void)?

    public init(config: Config, journal: Journal = Journal(), trasher: any Trasher = Trash.default()) {
        self.config = config; self.journal = journal; self.trasher = trasher
    }

    /// How many HEIC → JPEG conversions run at once before the (sequential) journal and moves.
    public var conversionConcurrency = 3

    public func commit(_ proposals: [Proposal], batch: String = Journal.newBatchID()) throws -> [Outcome] {
        // Step 1 for every file first, in parallel: hashing and converting don't depend on each
        // other or on the journal, and conversion is the slow part of a burst.
        let prepared = Prepared.Box(count: proposals.count)
        let work = proposals.indices.filter { proposals[$0].action != .skip && proposals[$0].target != nil }
        let lanes = max(1, min(conversionConcurrency, work.count))
        let config = self.config
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for j in stride(from: lane, to: work.count, by: lanes) {
                let i = work[j]
                prepared.set(i, Result { try Self.prepare(proposals[i], config: config) })
            }
        }
        var out: [Outcome] = []
        for (i, p) in proposals.enumerated() {
            guard p.action != .skip, let target = p.target else {
                out.append(Outcome(source: p.source, status: .skipped, message: p.reason))
                continue
            }
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                let prep = try prepared.get(i)!.get()
                var o = try commitOne(p, target: URL(fileURLWithPath: target), batch: batch, prepared: prep)
                var t = p.timings ?? StageTimings()
                t.merge(prep.timings)
                t.add(.commit, seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                o.timings = t
                out.append(o)
            } catch let crash as SimulatedCrash {
                throw crash
            } catch {
                out.append(Outcome(source: p.source, status: .failed, message: "\(error)"))
            }
        }
        return out
    }

    /// The source's hash and, for a conversion, the finished and synced temp JPEG.
    struct Prepared: Sendable {
        var sourceSHA1: String
        var temp: URL?
        var outputSHA1: String
        var timings = StageTimings()

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [Result<Prepared, any Error>?]
            init(count: Int) { items = Array(repeating: nil, count: count) }
            func set(_ i: Int, _ r: Result<Prepared, any Error>) { lock.lock(); items[i] = r; lock.unlock() }
            func get(_ i: Int) -> Result<Prepared, any Error>? { lock.lock(); defer { lock.unlock() }; return items[i] }
        }
    }

    /// Step 1: convert to a hidden temp file in the target folder and fsync it. Removes its temp on failure.
    static func prepare(_ p: Proposal, config: Config) throws -> Prepared {
        let source = URL(fileURLWithPath: p.source)
        let sourceSHA1 = try FileOps.sha1(source)
        var prep = Prepared(sourceSHA1: sourceSHA1, outputSHA1: sourceSHA1)
        guard p.action == .convert, let target = p.target else { return prep }
        let t = URL(fileURLWithPath: target).deletingLastPathComponent().appendingPathComponent(".betterairdrop-\(UUID().uuidString).jpg.tmp")
        do {
            try prep.timings.time(.convert) {
                try Converter.toJPEG(source: source, destination: t, quality: config.jpegQuality, stripGPS: config.stripGPSFromOutput)
                FileOps.copyDates(from: source, to: t)
                try FileOps.fsync(t)
            }
            prep.outputSHA1 = try FileOps.sha1(t)
            prep.temp = t
            return prep
        } catch {
            try? FileManager.default.removeItem(at: t)
            throw error
        }
    }

    func commitOne(_ p: Proposal, target planned: URL, batch: String, prepared prep: Prepared) throws -> Outcome {
        let source = URL(fileURLWithPath: p.source)
        let dir = planned.deletingLastPathComponent()
        let sourceSHA1 = prep.sourceSHA1
        var temp = prep.temp
        var placed: URL?
        var begun: JournalRecord?
        var trashed: URL?
        var deletedOriginal = false

        do {
            let outputSHA1 = prep.outputSHA1
            if temp != nil { try fault?(.tempWritten, source) }

            // Re-check the planned name: something may have appeared since planning.
            let stem = planned.deletingPathExtension().lastPathComponent
            let ext = planned.pathExtension
            var dest = FileOps.exists(planned) ? CollisionResolver.resolve(directory: dir, stem: stem, ext: ext) : planned

            let summary = p.suggestion.map { "\($0.kind.rawValue): \($0.subject)" } ?? p.context.map { $0.kind.rawValue }
            let rec = JournalRecord(op: .begin, batch: batch, action: p.action, source: source.path, target: dest.path,
                                    sourceSHA1: sourceSHA1, outputSHA1: outputSHA1,
                                    originals: p.action == .convert ? config.originals.rawValue : nil,
                                    backend: p.suggestion?.backend ?? backend, summary: summary,
                                    costUSD: p.suggestion?.usage?.cost())
            try journal.append(rec)
            begun = rec
            try fault?(.journaledBegin, source)

            // Move into place. On a race, take the next free name and journal the change.
            let from = temp ?? source
            while true {
                do { try FileOps.renameExclusive(from, dest); break }
                catch let e as POSIXError where e.code == .EEXIST {
                    dest = CollisionResolver.resolve(directory: dir, stem: stem, ext: ext)
                    var moved = rec; moved.target = dest.path
                    try journal.append(moved)
                    begun = moved
                }
            }
            placed = dest
            temp = nil
            try? FileOps.fsyncDirectory(dir)
            try fault?(.movedIntoPlace, source)

            try Marker(batch: batch, sourceSHA1: sourceSHA1).write(dest)
            try fault?(.marked, source)

            if p.action == .convert {
                switch config.originals {
                case .trash: trashed = try trasher.trash(source)
                case .delete: try FileManager.default.removeItem(at: source); deletedOriginal = true
                case .keep:
                    // Mark the kept original too, or the next run would convert it again.
                    try Marker(batch: batch, sourceSHA1: sourceSHA1).write(source)
                }
            }
            try fault?(.originalHandled, source)
            try journal.append(begun!.with(.done, trashed: trashed?.path))
            return Outcome(source: source.path, target: dest.path, status: .done, trashed: trashed?.path)
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            // Roll back whatever happened, newest first. The source is never modified before step 5.
            if let temp { try? FileManager.default.removeItem(at: temp) }
            if let t = trashed { try? FileOps.renameExclusive(t, source) }
            Marker.remove(source)
            if let placed, !deletedOriginal {
                if p.action == .convert {
                    try? FileManager.default.removeItem(at: placed)
                } else {
                    Marker.remove(placed)
                    try? FileOps.renameExclusive(placed, source)
                }
            }
            if let begun { try? journal.append(begun.with(.error, message: "\(error)")) }
            throw error
        }
    }

    /// Removes leftover `.betterairdrop-*.tmp` files older than a minute (from a crash mid-conversion).
    public static func sweepTemporaries(in dir: URL, olderThan age: TimeInterval = 60) {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in items where (u.lastPathComponent.hasPrefix(".betterairdrop-") || u.lastPathComponent.hasPrefix(".airname-")) && u.pathExtension == "tmp" {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(m) > age { try? FileManager.default.removeItem(at: u) }
        }
    }
}

extension FileOps {
    static func fsyncDirectory(_ dir: URL) throws {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = Darwin.fsync(fd)
    }
}
