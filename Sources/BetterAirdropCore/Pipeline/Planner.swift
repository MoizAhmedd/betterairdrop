import Foundation

/// Turns files into `Proposal`s: context → namer → template → collision-free path.
/// Pure planning; nothing on disk changes here.
public struct Planner: Sendable {
    public static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "dng"]
    static let heicExtensions: Set<String> = ["heic", "heif"]
    static let partialSuffixes = [".download", ".partial", ".crdownload"]

    public var config: Config
    public var places: Places?
    public var namer: (any Namer)?
    public var analyzer: (@Sendable (URL) -> VisionResult?)?
    public var templateOverride: String?
    public var airdropOnly = false

    public init(config: Config, places: Places? = Places.shared, namer: (any Namer)? = nil) {
        self.config = config
        self.places = config.placeProvider == .none ? nil : places
        self.namer = namer
    }

    /// Why a file shouldn't be touched, or nil if it's a candidate.
    public func skipReason(_ url: URL) -> String? {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return "hidden file" }
        if Self.partialSuffixes.contains(where: { name.hasSuffix($0) }) { return "still downloading" }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return "no such file" }
        if isDir.boolValue { return "is a directory" }
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return "not a supported image" }
        if Marker.read(url) != nil { return "already named by BetterAirdrop" }
        if !ImageIntegrity.isComplete(url) { return "incomplete image file" }
        if name.range(of: #"^\d{4}-\d{2}-\d{2}_"#, options: .regularExpression) != nil { return "already has a date-first name" }
        if airdropOnly && !(Quarantine.of(url)?.isAirDrop ?? false) { return "not from AirDrop" }
        return nil
    }

    public func context(for url: URL) throws -> PhotoContext {
        var t = StageTimings()
        return try context(for: url, timings: &t)
    }

    func context(for url: URL, timings t: inout StageTimings) throws -> PhotoContext {
        let meta = try PhotoMetadata.read(url)
        var ctx = PhotoContext(file: url.path, metadata: meta, airdrop: Quarantine.of(url)?.isAirDrop ?? false)
        if let lat = meta.latitude, let lon = meta.longitude {
            ctx.place = places?.nearest(latitude: lat, longitude: lon)
        }
        if let analyzer { ctx.vision = t.time(.vision) { analyzer(url) } }
        (ctx.kind, ctx.kindReason) = KindClassifier.classify(metadata: meta, vision: ctx.vision)
        return ctx
    }

    public func willConvert(_ url: URL) -> Bool {
        config.convertHEIC && Self.heicExtensions.contains(url.pathExtension.lowercased())
    }

    /// How many files are analysed and named at once (Vision + a cloud request each).
    public var concurrency = 4

    /// Plans a batch. Targets are unique within the batch and don't collide with existing files.
    /// Context extraction and naming run concurrently; names are composed in input order.
    public func plan(_ urls: [URL]) -> [Proposal] {
        let urls = urls.map(\.standardizedFileURL)
        let skips = urls.map(skipReason)
        let todo = urls.indices.filter { skips[$0] == nil }
        let results = Results(count: urls.count)
        // Striped so at most `concurrency` files are in flight. concurrentPerform runs work on the
        // calling thread too, so it can't deadlock even when no other thread is free.
        let lanes = max(1, min(concurrency, todo.count))
        let planner = self
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for j in stride(from: lane, to: todo.count, by: lanes) {
                let i = todo[j]
                results.set(i, Result { try planner.analyse(urls[i]) })
            }
        }

        var reserved = Set<String>()
        return urls.indices.map { i in
            let url = urls[i]
            if let why = skips[i] { return .skip(url, why) }
            do {
                let a = try results.get(i)!.get()
                return try finish(url, analysis: a, reserved: &reserved)
            } catch { return .skip(url, "\(error)") }
        }
    }

    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Result<Analysis, any Error>?]
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ r: Result<Analysis, any Error>) { lock.lock(); items[i] = r; lock.unlock() }
        func get(_ i: Int) -> Result<Analysis, any Error>? { lock.lock(); defer { lock.unlock() }; return items[i] }
    }

    /// A file's local context and suggested name, before a target path is picked.
    public struct Analysis: Sendable {
        public var context: PhotoContext
        public var suggestion: NameSuggestion?
        public var timings: StageTimings
    }

    /// The slow, parallelisable part: local context, then the namer.
    public func analyse(_ url: URL) throws -> Analysis {
        var t = StageTimings()
        let ctx = try context(for: url, timings: &t)
        var suggestion: NameSuggestion?
        if let namer, case .ready = namer.availability() {
            suggestion = try? namer.suggest(for: url, context: ctx)
        }
        t.merge(suggestion?.timings)
        return Analysis(context: ctx, suggestion: suggestion, timings: t)
    }

    func finish(_ url: URL, analysis a: Analysis, reserved: inout Set<String>) throws -> Proposal {
        let ctx = a.context, suggestion = a.suggestion
        let (stem, template, tokens) = try compose(url: url, context: ctx, suggestion: suggestion)
        let convert = willConvert(url)
        let ext = convert ? "jpg" : Self.normalizedExtension(url.pathExtension)
        let dir = url.deletingLastPathComponent()
        let target = CollisionResolver.resolve(directory: dir, stem: stem, ext: ext, reserved: reserved, ignoring: url)
        if target.path == url.path { return .skip(url, "name unchanged") }
        reserved.insert(target.path.lowercased())
        return Proposal(source: url.path, action: convert ? .convert : .rename, target: target.path,
                        template: template, tokens: tokens, context: ctx, suggestion: suggestion, timings: a.timings)
    }

    /// Builds the stem from context + suggestion. Returns the stem, the template used and the token values.
    public func compose(url: URL, context ctx: PhotoContext, suggestion: NameSuggestion?) throws -> (String, String, [String: String]) {
        let meta = ctx.metadata
        let kind = suggestion?.kind ?? ctx.kind
        var t: [String: String] = [
            "date": meta.date ?? "",
            "time": meta.time ?? "",
            "place": ctx.place.map { Slug.make($0.city, trimStopWords: false, maxChars: 30) } ?? "",
            "country": ctx.place?.countryCode.lowercased() ?? "",
            "kind": kind.rawValue,
            "device": meta.deviceSlug ?? "",
            "orig": Slug.make(url.deletingPathExtension().lastPathComponent, trimStopWords: false, maxChars: 40),
        ]
        if let s = suggestion, s.confidence >= 0.3 {
            t["subject"] = Slug.make(s.subject, maxWords: config.maxSubjectWords, maxChars: 60)
            t["merchant"] = s.merchant.map { Slug.make($0, maxWords: 3, maxChars: 30) }
            t["total"] = s.total.map { Slug.make($0, trimStopWords: false, maxChars: 12) }
        }
        let source = templateOverride ?? (kind == .photo ? config.template : config.kindTemplates[kind.rawValue] ?? config.template)
        let template = try Template(source)
        if let stem = template.render(t), stem != t["date"] { return (stem, source, t) }
        // Receipts without a merchant/total fall back to the screenshot-style subject if we have one.
        if kind != .photo, let subject = t["subject"], !subject.isEmpty,
           let stem = try Template("{date}_\(kind.rawValue)_{subject}").render(t) {
            return (stem, "{date}_\(kind.rawValue)_{subject}", t)
        }
        let fallback = kind == .photo ? Template.fallback : Template(unchecked: "{date}_\(kind.rawValue)_{orig}")
        guard let stem = fallback.render(t) else { throw PlanError.noName }
        return (stem, fallback.source, t)
    }

    static func normalizedExtension(_ ext: String) -> String {
        let e = ext.lowercased()
        return e == "jpeg" ? "jpg" : e
    }

    enum PlanError: Error, CustomStringConvertible {
        case noName
        var description: String { "couldn't build a name" }
    }
}
