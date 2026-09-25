import Foundation

/// Where betterairdrop keeps its state. `BETTERAIRDROP_HOME` overrides it (tests, portable runs).
public enum Paths {
    public static var supportDirectory: URL {
        if let p = ProcessInfo.processInfo.environment["BETTERAIRDROP_HOME"] { return URL(fileURLWithPath: p) }
        _ = LegacyMigration.once
        return defaultSupportDirectory
    }
    static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("betterairdrop")
    }
    public static var journal: URL { supportDirectory.appendingPathComponent("journal.jsonl") }
}

/// One line of `journal.jsonl`.
public struct JournalRecord: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        /// About to make the change (output written and synced, not yet in place).
        case begin
        /// The change is complete, including what happened to the original.
        case done
        /// The change failed and was rolled back.
        case error
        /// The change was reversed by `betterairdrop undo`.
        case undo
    }
    public var v = 1
    public var op: Op
    public var batch: String
    public var time: String
    public var action: Proposal.Action
    public var source: String
    public var target: String
    public var sourceSHA1: String
    /// SHA-1 of the output file (equals sourceSHA1 for plain renames).
    public var outputSHA1: String
    public var originals: String?
    public var trashed: String?
    public var backend: String?
    public var summary: String?
    public var message: String?
    /// What naming this file cost at list price, in US dollars (cloud backends only).
    public var costUSD: Double?

    public init(op: Op, batch: String, action: Proposal.Action, source: String, target: String,
                sourceSHA1: String, outputSHA1: String, originals: String? = nil, trashed: String? = nil,
                backend: String? = nil, summary: String? = nil, message: String? = nil, costUSD: Double? = nil) {
        self.op = op; self.batch = batch; self.time = Journal.timestamp()
        self.action = action; self.source = source; self.target = target
        self.sourceSHA1 = sourceSHA1; self.outputSHA1 = outputSHA1; self.originals = originals
        self.trashed = trashed; self.backend = backend; self.summary = summary; self.message = message
        self.costUSD = costUSD
    }

    func with(_ op: Op, trashed: String? = nil, message: String? = nil) -> JournalRecord {
        var r = self
        r.op = op; r.time = Journal.timestamp()
        if let trashed { r.trashed = trashed }
        r.message = message
        return r
    }
}

/// Append-only JSONL journal. Every append is fsynced before the next filesystem step.
public final class Journal: @unchecked Sendable {
    public let url: URL
    public static let rotateBytes = 10 * 1024 * 1024

    public init(url: URL = Paths.journal) { self.url = url }

    public func append(_ record: JournalRecord) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try enc.encode(record)
        line.append(0x0a)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard written == line.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
    }

    /// All records, oldest first, including the rotated file. Unreadable lines are skipped.
    public func records() -> [JournalRecord] {
        let dec = JSONDecoder()
        return [rotatedURL, url].flatMap { u -> [JournalRecord] in
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? dec.decode(JournalRecord.self, from: Data($0.utf8)) }
        }
    }

    var rotatedURL: URL { url.deletingPathExtension().appendingPathExtension("1.jsonl") }

    func rotateIfNeeded() {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.rotateBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }

    static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    public static func newBatchID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date()) + "-" + UUID().uuidString.prefix(4).lowercased()
    }

    /// The latest state of each change: one entry per (batch, source), in journal order.
    public struct Entry: Sendable {
        public var begin: JournalRecord
        public var latest: JournalRecord
        public var state: JournalRecord.Op { latest.op }
    }

    public func entries() -> [Entry] {
        var order: [String] = []
        var map: [String: Entry] = [:]
        for r in records() {
            let key = r.batch + "\u{0}" + r.source
            if r.op == .begin {
                if map[key] == nil { order.append(key) }
                map[key] = Entry(begin: r, latest: r)
            } else if map[key] != nil {
                map[key]!.latest = r
            }
        }
        return order.compactMap { map[$0] }
    }

    /// One batch as the app shows it: newest-first lists of these drive the menu's Recent rows,
    /// the History window and "Undo last batch".
    public struct BatchSummary: Sendable {
        public var id: String
        /// When the batch started (its first record).
        public var time: Date
        public var entries: [Entry]
        /// Entries that can still be undone.
        public var undoable: [Entry] { entries.filter { $0.state == .done || $0.state == .begin } }
        public var backend: String? { entries.compactMap(\.begin.backend).first }
        public var costUSD: Double { entries.compactMap(\.begin.costUSD).reduce(0, +) }
    }

    /// The most recent batches, newest first.
    public func recentBatches(limit: Int = 20) -> [BatchSummary] {
        Self.batches(entries(), limit: limit)
    }

    static func batches(_ entries: [Entry], limit: Int) -> [BatchSummary] {
        var order: [String] = []
        var groups: [String: [Entry]] = [:]
        for e in entries {
            if groups[e.begin.batch] == nil { order.append(e.begin.batch) }
            groups[e.begin.batch, default: []].append(e)
        }
        return order.reversed().prefix(limit).map { id in
            let es = groups[id]!
            return BatchSummary(id: id, time: Journal.date(es[0].begin.time) ?? .distantPast, entries: es)
        }
    }

    /// Renames and Claude spend since `since` (e.g. the start of this month). Undone renames still
    /// count toward spend, because the API call was made.
    public struct Stats: Sendable, Equatable {
        public var photos = 0
        public var costUSD = 0.0
    }

    public func stats(since: Date) -> Stats {
        var s = Stats()
        for e in entries() {
            guard let t = Journal.date(e.begin.time), t >= since else { continue }
            s.costUSD += e.begin.costUSD ?? 0
            if e.state == .done, (e.begin.source as NSString).pathExtension.lowercased() != "mov" { s.photos += 1 }
        }
        return s
    }

    public static func date(_ timestamp: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: timestamp)
    }
}
