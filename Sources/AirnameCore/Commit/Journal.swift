import Foundation

/// Where airname keeps its state. `AIRNAME_HOME` overrides it (tests, portable runs).
public enum Paths {
    public static var supportDirectory: URL {
        if let p = ProcessInfo.processInfo.environment["AIRNAME_HOME"] { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("airname")
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
        /// The change was reversed by `airname undo`.
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

    public init(op: Op, batch: String, action: Proposal.Action, source: String, target: String,
                sourceSHA1: String, outputSHA1: String, originals: String? = nil, trashed: String? = nil,
                backend: String? = nil, summary: String? = nil, message: String? = nil) {
        self.op = op; self.batch = batch; self.time = Journal.timestamp()
        self.action = action; self.source = source; self.target = target
        self.sourceSHA1 = sourceSHA1; self.outputSHA1 = outputSHA1; self.originals = originals
        self.trashed = trashed; self.backend = backend; self.summary = summary; self.message = message
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
}
