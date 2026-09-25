import Foundation

/// Watches one folder (by default ~/Downloads) for AirDrop arrivals and names them in batches.
///
/// Intake rules (PLAN.md §5, D4):
/// - top level only; images (`heic heif jpg jpeg png dng`) plus `.mov` Live Photo partners
/// - `com.apple.quarantine` agent must be `sharingd` (unless `airdropOnly` is off)
/// - no `dev.betterairdrop.done` marker, no dotfiles, no `.download`/`.partial`/`.crdownload`
/// - arrived after the watcher started (quarantine time), unless `backlog` is on, so starting the
///   watcher never renames a folder's worth of old AirDrops by surprise
/// - settled: size and mtime unchanged for `settleInterval`, and the image container is complete
/// - batched: processed together once nothing new has appeared for `quietWindow`
/// - Live Photos: `IMG_1.HEIC` + `IMG_1.MOV` in the same batch; the MOV gets the still's new name.
///   An orphan MOV is left alone.
public final class Watcher {
    public struct Options: Sendable {
        public var folder: URL
        public var airdropOnly = true
        public var backlog = false
        public var settleInterval: TimeInterval = 0.75
        public var quietWindow: TimeInterval = 3
        /// Give up waiting on a file that never settles (a stalled transfer) after this long.
        public var maxWait: TimeInterval = 60
        public var pollInterval: TimeInterval = 0.25

        public init(folder: URL) { self.folder = folder }
    }

    public struct Batch: Sendable {
        public var id: String
        public var proposals: [Proposal]
        public var outcomes: [Committer.Outcome]
        public var photos: Int { outcomes.filter { $0.status == .done && !Watcher.isMovie($0.source) }.count }
        public var videos: Int { outcomes.filter { $0.status == .done && Watcher.isMovie($0.source) }.count }
        public var failed: Int { outcomes.filter { $0.status == .failed }.count }
    }

    public let options: Options
    public var planner: Planner
    public let committer: Committer
    /// Called once per processed batch.
    public var onBatch: (Batch) -> Void = { _ in }
    /// Posts the one notification per batch (the CLI uses `OSAScriptNotifier`; the app its own).
    public var notifier: (any BatchNotifier)?
    /// While paused, arrivals are ignored, not queued: `resume()` moves `startedAt` forward so
    /// nothing that landed during the pause is renamed afterwards.
    public var isPaused: Bool { paused.value }
    private let paused = LockedFlag()
    public var log: (String) -> Void = { _ in }

    public private(set) var startedAt: Date
    /// Files we decided not to touch, keyed by path, with the fingerprint at the time. A change to the
    /// file (new size/mtime) makes it a candidate again.
    var ignored: [String: Fingerprint] = [:]

    static let movieExtensions: Set<String> = ["mov"]

    public init(options: Options, planner: Planner, committer: Committer, startedAt: Date = Date()) {
        self.options = options
        self.planner = planner
        self.planner.airdropOnly = options.airdropOnly
        self.committer = committer
        // Quarantine timestamps have 1 s resolution; allow a little slack.
        self.startedAt = startedAt.addingTimeInterval(-2)
    }

    /// Safe to call from any thread; a batch in progress stops waiting for new files.
    public func pause() { paused.value = true }

    /// Resumes watching. Only files arriving from now on are candidates (unless `backlog` is on).
    public func resume(at date: Date = Date()) {
        paused.value = false
        startedAt = date.addingTimeInterval(-2)
    }

    /// Forgets files that were skipped or failed, so they can be tried again ("Rename Again").
    public func resetIgnored() { ignored = [:] }

    static func isMovie(_ path: String) -> Bool { movieExtensions.contains((path as NSString).pathExtension.lowercased()) }

    struct Fingerprint: Equatable { var size: Int64; var mtime: TimeInterval }

    static func fingerprint(_ url: URL) -> Fingerprint? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let m = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
        return Fingerprint(size: Int64(st.st_size), mtime: m)
    }

    /// When the file arrived: the quarantine time if there is one, else the inode change time
    /// (birth and modification dates are copied from the iPhone, so they can be months old).
    static func arrival(_ url: URL, quarantine: Quarantine?) -> Date? {
        if let t = quarantine?.timestamp { return t }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec))
    }

    /// Current candidates, cheapest checks first. Doesn't wait or read pixels.
    public func scan() -> [URL] {
        if isPaused { return [] }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: options.folder.path) else { return [] }
        var out: [URL] = []
        for name in names.sorted() {
            if name.hasPrefix(".") || Planner.partialSuffixes.contains(where: { name.hasSuffix($0) }) { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            guard Planner.imageExtensions.contains(ext) || Self.movieExtensions.contains(ext) else { continue }
            let url = options.folder.appendingPathComponent(name)
            guard let fp = Self.fingerprint(url) else { continue }
            if let old = ignored[url.path], old == fp { continue }
            let q = Quarantine.of(url)
            if options.airdropOnly && !(q?.isAirDrop ?? false) { continue }
            if Marker.read(url) != nil { continue }
            if !options.backlog, let t = Self.arrival(url, quarantine: q), t < startedAt { continue }
            out.append(url)
        }
        return out
    }

    func isComplete(_ url: URL) -> Bool {
        Self.isMovie(url.path) ? true : ImageIntegrity.isComplete(url)
    }

    /// Waits for candidates to settle and go quiet, then processes them as one batch.
    /// Returns nil if there was nothing to do (including only orphan videos).
    public func runOnce() -> Batch? {
        struct Seen { var fp: Fingerprint; var since: Date }
        var seen: [String: Seen] = [:]
        var lastActivity = Date()
        let start = Date()
        while true {
            let now = Date()
            let candidates = scan()
            if candidates.isEmpty && seen.isEmpty { return nil }
            let paths = Set(candidates.map(\.path))
            for gone in seen.keys where !paths.contains(gone) { seen[gone] = nil; lastActivity = now }
            for url in candidates {
                guard let fp = Self.fingerprint(url) else { continue }
                if seen[url.path]?.fp != fp { seen[url.path] = Seen(fp: fp, since: now); lastActivity = now }
            }
            if seen.isEmpty { return nil }
            let settled = candidates.filter { u in
                guard let s = seen[u.path] else { return false }
                return now.timeIntervalSince(s.since) >= options.settleInterval && isComplete(u)
            }
            let quiet = now.timeIntervalSince(lastActivity) >= options.quietWindow
            let timedOut = now.timeIntervalSince(start) >= options.maxWait
            if (settled.count == seen.count && quiet) || (timedOut && !settled.isEmpty) {
                if settled.count < seen.count {
                    log("still incomplete after \(Int(options.maxWait)) s, left for later: "
                        + seen.keys.filter { p in !settled.contains { $0.path == p } }.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                }
                let batch = process(settled)
                return batch.outcomes.isEmpty ? nil : batch
            }
            if timedOut && now.timeIntervalSince(start) >= options.maxWait * 2 {
                for p in seen.keys { ignored[p] = Self.fingerprint(URL(fileURLWithPath: p)) }
                log("gave up on files that never completed: \(seen.keys.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                return nil
            }
            Thread.sleep(forTimeInterval: options.pollInterval)
        }
    }

    /// Plans stills, pairs Live Photo MOVs with them, commits everything as one batch.
    public func process(_ urls: [URL]) -> Batch {
        let stills = urls.filter { !Self.isMovie($0.path) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let movies = urls.filter { Self.isMovie($0.path) }
        let stem = { (u: URL) in u.deletingPathExtension().lastPathComponent.lowercased() }
        var movieFor: [String: URL] = [:]
        for m in movies {
            if stills.contains(where: { stem($0) == stem(m) }) { movieFor[stem(m)] = m }
            else { ignore(m, "a video without a matching photo in this batch (only Live Photo videos are renamed)") }
        }

        let planned = planner.plan(stills)
        var reserved = Set(planned.compactMap { $0.target?.lowercased() })
        var proposals: [Proposal] = []
        for p in planned {
            proposals.append(p)
            let still = URL(fileURLWithPath: p.source)
            guard let mov = movieFor[stem(still)] else { continue }
            guard p.action != .skip, let target = p.target else {
                ignore(mov, "its Live Photo still was skipped")
                continue
            }
            let newStem = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
            let movTarget = CollisionResolver.resolve(directory: mov.deletingLastPathComponent(), stem: newStem,
                                                      ext: mov.pathExtension.lowercased(), reserved: reserved, ignoring: mov)
            reserved.insert(movTarget.path.lowercased())
            var mp = Proposal(source: mov.path, action: .rename, target: movTarget.path)
            mp.template = "Live Photo video: same name as \((target as NSString).lastPathComponent)"
            mp.suggestion = p.suggestion
            proposals.append(mp)
        }

        let id = Journal.newBatchID()
        let outcomes = (try? committer.commit(proposals, batch: id)) ?? []
        for o in outcomes where o.status != .done {
            ignore(URL(fileURLWithPath: o.source), o.message ?? o.status.rawValue)
        }
        let batch = Batch(id: id, proposals: proposals, outcomes: outcomes)
        if batch.photos + batch.videos + batch.failed > 0 {
            onBatch(batch)
            notifier?.notify(batch)
        }
        return batch
    }

    func ignore(_ url: URL, _ why: String) {
        ignored[url.path] = Self.fingerprint(url)
        log("skip \(url.lastPathComponent): \(why)")
    }

    /// Runs until `shouldStop` returns true, polling between batches.
    public func run(shouldStop: () -> Bool = { false }) {
        while !shouldStop() {
            if runOnce() == nil { Thread.sleep(forTimeInterval: max(options.pollInterval, 0.5)) }
        }
    }

    /// The notification text for a batch, e.g. "Renamed 6 photos (1 Live Photo video)".
    public static func summary(_ b: Batch) -> String {
        var s = "Renamed \(b.photos) photo\(b.photos == 1 ? "" : "s")"
        if b.videos > 0 { s += " (+\(b.videos) Live Photo video\(b.videos == 1 ? "" : "s"))" }
        if b.failed > 0 { s += ", \(b.failed) failed" }
        return s
    }
}

/// Posts one notification per batch.
public protocol BatchNotifier {
    func notify(_ batch: Watcher.Batch)
}

/// The CLI's notifier: `osascript`, which works from Terminal without an app bundle (macOS shows it
/// as coming from Script Editor). The menu-bar app posts its own, with Undo and Show in Finder.
public struct OSAScriptNotifier: BatchNotifier {
    public init() {}
    public func notify(_ batch: Watcher.Batch) {
        Notifier.post(title: "BetterAirdrop", message: "\(Watcher.summary(batch)) · undo: betterairdrop undo")
    }
}

/// One macOS notification via `osascript`.
public enum Notifier {
    public static func post(title: String, message: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(message))\" with title \"\(esc(title))\""]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

/// `flock` on a file in the state directory so only one watcher processes a folder at a time.
/// The holder describes itself in `lock.owner` (JSON), so the CLI can say "the app is already
/// watching" instead of a bare "already running", and `status` can report the app's state.
public final class ProcessLock {
    public struct Owner: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case app, cli }
        public var kind: Kind
        public var pid: Int32
        public var folder: String
        public var paused: Bool
        public init(kind: Kind, pid: Int32 = getpid(), folder: String, paused: Bool = false) {
            self.kind = kind; self.pid = pid; self.folder = folder; self.paused = paused
        }
    }

    let fd: Int32
    public let url: URL
    public static var defaultURL: URL { Paths.supportDirectory.appendingPathComponent("lock") }
    static func ownerURL(_ lock: URL) -> URL { lock.appendingPathExtension("owner") }

    public init?(_ url: URL = ProcessLock.defaultURL, owner: Owner? = nil) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        self.fd = fd
        self.url = url
        if let owner { update(owner) }
    }

    /// Rewrites the owner record (e.g. when the app pauses).
    public func update(_ owner: Owner) {
        guard let d = try? JSONEncoder().encode(owner) else { return }
        try? d.write(to: Self.ownerURL(url), options: .atomic)
    }

    deinit {
        try? FileManager.default.removeItem(at: Self.ownerURL(url))
        flock(fd, LOCK_UN); close(fd)
    }

    /// Who holds the lock right now, or nil if nobody does (a stale owner file is ignored).
    public static func holder(_ url: URL = ProcessLock.defaultURL) -> Owner? {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }   // free
        guard let d = try? Data(contentsOf: ownerURL(url)), let o = try? JSONDecoder().decode(Owner.self, from: d),
              kill(o.pid, 0) == 0 || errno == EPERM else { return Owner(kind: .cli, pid: 0, folder: "") }
        return o
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
