@testable import AirnameCore
import CoreGraphics
import Foundation
import Testing

/// Live end-to-end naming tests against the real Claude API. Opt-in and never part of a plain
/// `swift test`:
///
///     AIRNAME_E2E=1 swift test --filter E2E      (or scripts/e2e.sh)
///
/// Inputs: the gitignored `fixtures-local/` photos (copied to a temp folder; the originals are
/// never touched) plus synthetic receipt/document/screenshot images. Output: `e2e-report.html`
/// and `e2e-results.json` in the repo root (both gitignored: they contain thumbnails and OCR text).
enum E2E {
    static let enabled = ProcessInfo.processInfo.environment["AIRNAME_E2E"] == "1"
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repo.appendingPathComponent("fixtures-local")
    static let inputPerMillion = 1.0, outputPerMillion = 5.0   // Haiku 4.5 pricing, USD

    /// Common given names; a subject containing one is treated as naming a person.
    static let givenNames: Set<String> = [
        "james", "john", "robert", "michael", "william", "david", "richard", "joseph", "thomas", "charles", "daniel", "matthew",
        "anthony", "mark", "steven", "paul", "andrew", "joshua", "kevin", "brian", "george", "edward", "ryan", "jacob", "nicholas",
        "mary", "patricia", "jennifer", "linda", "elizabeth", "barbara", "susan", "jessica", "sarah", "karen", "nancy", "lisa",
        "emily", "emma", "olivia", "sophia", "ava", "mia", "chloe", "anna", "laura", "rachel", "hannah", "julia", "grace",
        "ahmed", "mohammed", "muhammad", "ali", "omar", "hassan", "fatima", "aisha", "sara", "priya", "raj", "wei",
    ]
    static let fallbackPatterns = [#"(^|-)img-?\d+"#, #"^\d+$"#, #"(^|-)photo-img"#]

    struct Row: Codable {
        var file: String
        var thumbnail: String = ""
        var visionName: String = ""
        var claudeName: String = ""
        var subject: String = ""
        var kind: String = ""
        var expectedKind: String?
        var backend: String = ""
        var confidence: Double = 0
        var peoplePresent: Bool?
        var fallback: String?
        var context: String = ""
        var inputTokens = 0
        var outputTokens = 0
        var cost: Double = 0
        var problems: [String] = []
    }

    struct Run: Codable {
        var name: String
        var photos = 0
        var inputTokens = 0
        var outputTokens = 0
        var seconds = 0.0
        var cost: Double { Double(inputTokens) / 1e6 * inputPerMillion + Double(outputTokens) / 1e6 * outputPerMillion }
        enum CodingKeys: CodingKey { case name, photos, inputTokens, outputTokens, seconds }
    }

    /// Accumulates rows and runs from both tests and rewrites the report after each.
    final class Report: @unchecked Sendable {
        static let shared = Report()
        let lock = NSLock()
        var rows: [Row] = []
        var runs: [Run] = []
        var notes: [String] = []

        func add(rows r: [Row], run: Run, notes n: [String] = []) {
            lock.lock(); rows += r; runs.append(run); notes += n; lock.unlock()
            write()
        }

        func write() {
            lock.lock(); defer { lock.unlock() }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            var slim = rows
            for i in slim.indices { slim[i].thumbnail = ""; slim[i].context = "" }   // JSON: names and numbers only
            struct Out: Encodable { var runs: [Run]; var rows: [Row]; var notes: [String]; var structuredOutput: Bool; var model: String }
            let out = Out(runs: runs, rows: slim, notes: notes, structuredOutput: ClaudeNamer.structuredOutput.value, model: ClaudeNamer.defaultModel)
            try? enc.encode(out).write(to: repo.appendingPathComponent("e2e-results.json"))
            try? Data(html().utf8).write(to: repo.appendingPathComponent("e2e-report.html"))
        }

        func html() -> String {
            func esc(_ s: String) -> String {
                s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            }
            let totalIn = runs.reduce(0) { $0 + $1.inputTokens }, totalOut = runs.reduce(0) { $0 + $1.outputTokens }
            let totalCost = runs.reduce(0) { $0 + $1.cost }, totalPhotos = runs.reduce(0) { $0 + $1.photos }
            var h = """
            <!doctype html><meta charset="utf-8"><title>airname e2e report</title>
            <style>
            body{font:14px -apple-system,system-ui,sans-serif;margin:24px;color:#222}
            table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #ddd;padding:6px 8px;vertical-align:top;text-align:left}
            th{background:#f4f4f4;position:sticky;top:0}img{max-width:180px;max-height:180px;border-radius:4px}
            code{font:12px ui-monospace,monospace}.ctx{white-space:pre-wrap;font:11px ui-monospace,monospace;color:#555;max-width:380px}
            .bad{color:#b00020}.ok{color:#0a7d32}.num{text-align:right;font-variant-numeric:tabular-nums}
            </style>
            <h1>airname e2e: Claude vs Vision</h1>
            <p>Model <code>\(ClaudeNamer.defaultModel)</code> · structured output (output_config): <b>\(ClaudeNamer.structuredOutput.value ? "accepted" : "rejected, prompted JSON used")</b>
            · generated \(Journal.timestamp().prefix(19)) · pricing $\(Int(inputPerMillion))/M input, $\(Int(outputPerMillion))/M output</p>
            <table style="width:auto"><tr><th>Run</th><th class=num>Photos</th><th class=num>Input tokens</th><th class=num>Output tokens</th><th class=num>Cost (USD)</th><th class=num>Per photo</th><th class=num>Wall time</th></tr>
            """
            for r in runs {
                h += "<tr><td>\(esc(r.name))</td><td class=num>\(r.photos)</td><td class=num>\(r.inputTokens)</td><td class=num>\(r.outputTokens)</td>"
                h += "<td class=num>$\(String(format: "%.4f", r.cost))</td><td class=num>$\(String(format: "%.5f", r.photos > 0 ? r.cost / Double(r.photos) : 0))</td>"
                h += "<td class=num>\(String(format: "%.0f", r.seconds)) s</td></tr>"
            }
            h += "<tr><th>Total</th><th class=num>\(totalPhotos)</th><th class=num>\(totalIn)</th><th class=num>\(totalOut)</th><th class=num>$\(String(format: "%.4f", totalCost))</th>"
            h += "<th class=num>≈ $\(String(format: "%.2f", totalPhotos > 0 ? totalCost / Double(totalPhotos) * 1000 : 0)) / 1000 photos</th><th></th></tr></table>"
            if !notes.isEmpty { h += "<ul>" + notes.map { "<li>\(esc($0))</li>" }.joined() + "</ul>" }
            h += "<h2>Photos</h2><table><tr><th>Image</th><th>Old name</th><th>Vision name</th><th>Claude name</th><th>Details</th><th>Context sent (text)</th></tr>"
            for r in rows {
                let problems = r.problems.isEmpty ? "<span class=ok>checks pass</span>" : "<span class=bad>" + r.problems.map(esc).joined(separator: "<br>") + "</span>"
                h += "<tr><td>\(r.thumbnail.isEmpty ? "" : "<img src=\"data:image/jpeg;base64,\(r.thumbnail)\">")</td>"
                h += "<td><code>\(esc(r.file))</code></td><td><code>\(esc(r.visionName))</code></td><td><code><b>\(esc(r.claudeName))</b></code></td>"
                h += "<td>kind <b>\(esc(r.kind))</b>\(r.expectedKind.map { " (expected \(esc($0)))" } ?? "")<br>backend \(esc(r.backend))"
                h += "<br>confidence \(String(format: "%.2f", r.confidence))\(r.peoplePresent == true ? "<br>people present" : "")"
                h += "<br>\(r.inputTokens) in / \(r.outputTokens) out · $\(String(format: "%.5f", r.cost))"
                if let f = r.fallback { h += "<br><span class=bad>fallback: \(esc(f))</span>" }
                h += "<br>\(problems)</td><td class=ctx>\(esc(r.context))</td></tr>"
            }
            return h + "</table>"
        }
    }

    /// Vision results are cached per path so the Vision and Claude passes analyse each image once.
    final class VisionCache: @unchecked Sendable {
        let lock = NSLock()
        var map: [String: VisionResult?] = [:]
        func get(_ url: URL) -> VisionResult? {
            lock.lock(); if let v = map[url.path] { lock.unlock(); return v }; lock.unlock()
            let v = VisionAnalyzer.analyze(url)
            lock.lock(); map[url.path] = v; lock.unlock()
            return v
        }
    }

    static func thumbnail(_ url: URL) -> String {
        (try? UploadImage.jpeg(from: url, maxPixelSize: 240, quality: 0.7))?.base64EncodedString() ?? ""
    }

    /// Subject rules shared by both live tests. Returns the problems found (empty = pass).
    static func subjectProblems(_ subject: String) -> [String] {
        var p: [String] = []
        let words = subject.split(separator: "-").map(String.init)
        if !(2...6).contains(words.count) { p.append("subject has \(words.count) words (want 2–6): \(subject)") }
        if subject.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) == nil { p.append("subject isn't a lowercase slug: \(subject)") }
        for pat in fallbackPatterns where subject.range(of: pat, options: .regularExpression) != nil { p.append("subject is a fallback: \(subject)") }
        if words.allSatisfy({ VisionNamer.parents.contains($0) || ["photo", "image", "picture", "screenshot"].contains($0) }) {
            p.append("subject is only generic labels: \(subject)")
        }
        if let n = words.first(where: { givenNames.contains($0) }) { p.append("subject contains a person's name (\(n)): \(subject)") }
        return p
    }

    static func sha1(_ url: URL) -> String { (try? FileOps.sha1(url)) ?? "?" }

    static func copyFixtures(to dir: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
            .filter { Planner.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        return try names.map { n in
            let dst = dir.appendingPathComponent(n)
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(n), to: dst)   // keeps xattrs (creatorBundleID)
            return dst
        }
    }

    static var credentialAvailable: Bool { ClaudeAuth.shared.resolve() != nil }
}

@Suite(.enabled(if: E2E.enabled, "set AIRNAME_E2E=1 to run the live Claude e2e tests"), .serialized)
struct E2ENamingTests {
    /// The full pipeline on every local fixture plus synthetic receipt/document/screenshot:
    /// Vision names (dry run) vs Claude names (committed), then idempotency and undo.
    @Test func fullPipeline() throws {
        try #require(E2E.credentialAvailable, "no Anthropic credential: see `airname auth status`")
        try #require(FileManager.default.fileExists(atPath: E2E.fixtures.path), "fixtures-local/ is missing")
        let s = Sandbox()
        let dir = s.downloads
        var files = try E2E.copyFixtures(to: dir)
        // Synthetic, labelled fixtures (safe to describe anywhere).
        let render = VisionIntegrationTests.self
        let receipt = render.render([("LOBLAWS", 64), ("Queen St W Toronto", 26), ("BANANAS        2.49", 30), ("OAT MILK       5.99", 30),
                                     ("COFFEE BEANS  65.96", 30), ("SUBTOTAL      74.44", 30), ("HST            9.68", 30),
                                     ("TOTAL         84.12", 40), ("VISA          84.12", 30)],
                                    width: 700, page: CGRect(x: 100, y: 60, width: 500, height: 1280), to: dir.appendingPathComponent("SYN_receipt.JPG"))
        let document = render.render([("Lease Agreement", 56)] + (1...12).map { ("This agreement is made between the parties, clause \($0).", CGFloat(24)) },
                                     to: dir.appendingPathComponent("SYN_document.JPG"))
        let screenshot = render.render([("9:41", 22), ("Payments", 28), ("Failed payment", 60), ("Your card was declined.", 26)],
                                       width: 600, height: 1300, page: CGRect(x: 0, y: 0, width: 600, height: 1300),
                                       to: dir.appendingPathComponent("SYN_screenshot.PNG"), type: .png, meta: .init(gps: nil, userComment: "Screenshot"))
        files += [receipt, document, screenshot]
        let expectedKind: [String: Kind] = ["SYN_receipt.JPG": .receipt, "SYN_document.JPG": .document, "SYN_screenshot.PNG": .screenshot]

        // Ground truth from the originals, before anything moves.
        let places = Places.shared
        var truth: [String: (date: String?, city: String?, sha1: String, screenshot: Bool)] = [:]
        var rows: [String: E2E.Row] = [:]
        for u in files {
            let m = try PhotoMetadata.read(u)
            let city = m.latitude.flatMap { lat in places?.nearest(latitude: lat, longitude: m.longitude!) }.map { Slug.make($0.city, trimStopWords: false, maxChars: 30) }
            truth[u.lastPathComponent] = (m.dateSource == "exif" ? m.date : nil, city, E2E.sha1(u), m.isScreenshotByMetadata)
            rows[u.lastPathComponent] = E2E.Row(file: u.lastPathComponent, thumbnail: E2E.thumbnail(u))
        }

        let cache = E2E.VisionCache()
        var visionPlanner = Planner(config: Config(), places: places, namer: VisionNamer())
        visionPlanner.analyzer = { cache.get($0) }
        for p in visionPlanner.plan(files) {
            rows[(p.source as NSString).lastPathComponent]?.visionName = p.target.map { ($0 as NSString).lastPathComponent } ?? "skip: \(p.reason ?? "")"
        }

        var claudePlanner = Planner(config: Config(), places: places,
                                    namer: FallbackNamer(primary: ClaudeNamer(), fallback: VisionNamer()))
        claudePlanner.analyzer = { cache.get($0) }
        let t0 = Date()
        let proposals = claudePlanner.plan(files)
        var run = E2E.Run(name: "rename (\(files.count) files: fixtures-local + synthetic)", seconds: Date().timeIntervalSince(t0))

        for p in proposals {
            let name = (p.source as NSString).lastPathComponent
            var r = rows[name]!
            r.claudeName = p.target.map { ($0 as NSString).lastPathComponent } ?? "skip: \(p.reason ?? "")"
            if let ctx = p.context { r.context = ClaudePrompt.context(ctx) }
            if let sg = p.suggestion {
                r.subject = p.tokens?["subject"] ?? ""
                r.kind = sg.kind.rawValue; r.backend = sg.backend; r.confidence = sg.confidence; r.fallback = sg.fallbackFrom
                r.peoplePresent = sg.why.contains { $0.contains("people present") }
                if let u = sg.usage {
                    r.inputTokens = u.inputTokens; r.outputTokens = u.outputTokens; r.cost = u.cost()
                    run.photos += 1; run.inputTokens += u.inputTokens; run.outputTokens += u.outputTokens
                }
            }
            let t = truth[name]!
            let expected: Kind? = expectedKind[name] ?? (t.screenshot ? .screenshot : nil)
            r.expectedKind = expected?.rawValue
            if p.action == .skip { r.problems.append("skipped: \(p.reason ?? "")") }
            if r.backend != "claude" { r.problems.append("not named by Claude (\(r.fallback ?? r.backend))") }
            if let d = t.date, !r.claudeName.hasPrefix(d + "_") { r.problems.append("date: expected \(d)") }
            if let c = t.city, p.template?.contains("{place}") == true, !r.claudeName.contains("_\(c)_") { r.problems.append("place: expected \(c)") }
            if let k = expected, r.kind != k.rawValue { r.problems.append("kind: expected \(k.rawValue), got \(r.kind)") }
            r.problems += E2E.subjectProblems(r.subject)
            rows[name] = r
        }

        // Commit, then check outputs, a second run, and undo.
        let outcomes = try s.committer().commit(proposals)
        let batch = try #require(s.journal.records().first?.batch)
        var notes: [String] = []
        for o in outcomes where o.status != .done { notes.append("commit \(o.status.rawValue): \((o.source as NSString).lastPathComponent) \(o.message ?? "")") }
        for o in outcomes where o.status == .done {
            let name = (o.source as NSString).lastPathComponent
            if let d = truth[name]?.date, let out = o.target, (try? PhotoMetadata.read(URL(fileURLWithPath: out)))?.date != d {
                rows[name]?.problems.append("output file lost its EXIF date")
            }
        }
        let second = claudePlanner.plan(s.listing().map(s.file))
        let secondRunNoOp = second.allSatisfy { $0.action == .skip }
        if !secondRunNoOp { notes.append("second run would change: " + second.filter { $0.action != .skip }.map { ($0.source as NSString).lastPathComponent }.joined(separator: ", ")) }
        let undone = try s.undoer().undo(.batch(batch))
        let restored = files.allSatisfy { E2E.sha1($0) == truth[$0.lastPathComponent]!.sha1 }
        notes.append("rename: \(outcomes.filter { $0.status == .done }.count)/\(files.count) done · second run no-op: \(secondRunNoOp) · undo restored byte-identical: \(restored)")

        let ordered = files.map { rows[$0.lastPathComponent]! }
        E2E.Report.shared.add(rows: ordered, run: run, notes: notes)
        print("e2e: \(run.photos) Claude calls, \(run.inputTokens) in / \(run.outputTokens) out, $\(String(format: "%.4f", run.cost)), \(Int(run.seconds)) s; report: \(E2E.repo.appendingPathComponent("e2e-report.html").path)")

        // Assertions (after the report is written, so a failure still leaves something to look at).
        for r in ordered { #expect(r.problems.isEmpty, "\(r.file): \(r.problems.joined(separator: "; "))") }
        let targets = proposals.compactMap { $0.target?.lowercased() }
        #expect(Set(targets).count == targets.count, "filenames are unique")
        #expect(outcomes.allSatisfy { $0.status == .done })
        #expect(secondRunNoOp)
        #expect(undone.allSatisfy { $0.status == .restored })
        #expect(restored)
    }

    /// The watcher end to end with the real backend: a simulated AirDrop burst of 8 (one written
    /// slowly in chunks, one a Live Photo with its MOV) plus files that must be ignored.
    @Test func watcherBurst() throws {
        try #require(E2E.credentialAvailable, "no Anthropic credential: see `airname auth status`")
        try #require(FileManager.default.fileExists(atPath: E2E.fixtures.path), "fixtures-local/ is missing")
        let s = Sandbox()
        let staging = s.root.path("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let pool = try E2E.copyFixtures(to: staging)
        let picks = Array(pool.filter { $0.pathExtension.lowercased() == "heic" }.prefix(6)) + Array(pool.filter { $0.pathExtension == "PNG" }.prefix(2))
        try #require(picks.count == 8)
        // Bystanders: a non-AirDrop copy (empty agent, like a Finder copy) and a Safari download.
        let bystander = s.file("copied.HEIC"), safari = s.file("safari.HEIC")
        try FileManager.default.copyItem(at: picks[0], to: bystander)
        try FileManager.default.copyItem(at: picks[1], to: safari); AirDropSim.tag(safari, agent: "Safari")
        let bystanders = [bystander: E2E.sha1(bystander), safari: E2E.sha1(safari)]

        var planner = Planner(config: Config(), places: Places.shared, namer: FallbackNamer(primary: ClaudeNamer(), fallback: VisionNamer()))
        planner.analyzer = { VisionAnalyzer.analyze($0) }
        var o = Watcher.Options(folder: s.downloads)
        o.quietWindow = 1.5
        let w = Watcher(options: o, planner: planner, committer: s.committer())
        var batches: [Watcher.Batch] = []
        w.onBatch = { batches.append($0) }

        // First arrival is the slow chunked one; the rest land 100 ms apart while it's still writing.
        let slow = AirDropSim.slowWrite(try Data(contentsOf: picks[0]), to: s.file(picks[0].lastPathComponent), chunk: 256 * 1024, pause: 0.08)
        let livePhotoStem = picks[2].deletingPathExtension().lastPathComponent
        let writer = Thread {
            for u in picks.dropFirst() {
                Thread.sleep(forTimeInterval: 0.1)
                let dst = s.file(u.lastPathComponent)
                try! FileManager.default.copyItem(at: u, to: dst)
                AirDropSim.tag(dst)
                if u.deletingPathExtension().lastPathComponent == livePhotoStem {
                    let mov = s.file(livePhotoStem + ".MOV")
                    try! Data(repeating: 1, count: 300_000).write(to: mov); AirDropSim.tag(mov)
                }
            }
        }
        writer.start()
        let t0 = Date()
        let batch = try #require(w.runOnce())
        var run = E2E.Run(name: "watch (simulated AirDrop burst of 8 + Live Photo MOV)", seconds: Date().timeIntervalSince(t0))
        var rows: [E2E.Row] = []
        for p in batch.proposals where p.source.lowercased().hasSuffix(".mov") == false {
            var r = E2E.Row(file: "watch: " + (p.source as NSString).lastPathComponent)
            r.claudeName = p.target.map { ($0 as NSString).lastPathComponent } ?? "skip"
            r.subject = p.tokens?["subject"] ?? ""
            r.kind = p.suggestion?.kind.rawValue ?? ""; r.backend = p.suggestion?.backend ?? ""
            r.confidence = p.suggestion?.confidence ?? 0; r.fallback = p.suggestion?.fallbackFrom
            if let u = p.suggestion?.usage {
                r.inputTokens = u.inputTokens; r.outputTokens = u.outputTokens; r.cost = u.cost()
                run.photos += 1; run.inputTokens += u.inputTokens; run.outputTokens += u.outputTokens
            }
            r.problems = E2E.subjectProblems(r.subject)
            rows.append(r)
        }
        let movTarget = batch.outcomes.first { $0.source.hasSuffix(".MOV") }?.target
        let stillTarget = batch.proposals.first { ($0.source as NSString).lastPathComponent.hasPrefix(livePhotoStem + ".") && !$0.source.hasSuffix(".MOV") }?.target
        let paired = movTarget.map { ($0 as NSString).deletingPathExtension } == stillTarget.map { ($0 as NSString).deletingPathExtension }
        let bystandersOK = bystanders.allSatisfy { E2E.sha1($0.key) == $0.value }
        let again = w.runOnce()
        E2E.Report.shared.add(rows: rows, run: run, notes: [
            "watch: \(batches.count) batch(es), \(batch.photos) photos + \(batch.videos) video · Live Photo MOV paired: \(paired) · non-AirDrop files untouched: \(bystandersOK) · second pass no-op: \(again == nil)",
        ])

        #expect(batches.count == 1)
        #expect(batch.photos == 8 && batch.videos == 1 && batch.failed == 0)
        #expect(paired)
        #expect(bystandersOK)
        #expect(again == nil)
        #expect(slow.isFinished)
        for r in rows { #expect(r.problems.isEmpty && r.backend == "claude", "\(r.file): \(r.problems.joined(separator: "; ")) \(r.fallback ?? "")") }
        let undone = try s.undoer().undo(.batch(batch.id))
        #expect(undone.allSatisfy { $0.status == .restored })
    }
}
