@testable import BetterAirdropCore
@testable import BetterAirdropKit
import Foundation
import Testing

let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
let posix = Locale(identifier: "en_US_POSIX")
func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

final class Temp {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-kit-\(UUID().uuidString)")
    init() { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite struct PauseTests {
    @Test func resumeDates() {
        let now = at("2026-09-24T14:06:00Z")
        #expect(PauseDuration.oneHour.resumeDate(now: now, calendar: utc) == at("2026-09-24T15:06:00Z"))
        #expect(PauseDuration.untilTomorrow.resumeDate(now: now, calendar: utc) == at("2026-09-25T08:00:00Z"))
        #expect(PauseDuration.indefinitely.resumeDate(now: now, calendar: utc) == nil)
    }

    @Test func bannerText() {
        let now = at("2026-09-24T14:06:00Z")
        #expect(PauseText.banner(until: at("2026-09-24T15:06:00Z"), now: now, calendar: utc, locale: Locale(identifier: "en_GB"))
                == "Paused until 15:06. AirDrops will be left as they are.")
        #expect(PauseText.banner(until: at("2026-09-25T08:00:00Z"), now: now, calendar: utc, locale: Locale(identifier: "en_GB"))
                == "Paused until tomorrow at 08:00. AirDrops will be left as they are.")
        #expect(PauseText.banner(until: nil) == "Paused. AirDrops will be left as they are.")
    }
}

@Suite struct RelativeTimeTests {
    @Test func steps() {
        let now = at("2026-09-24T14:06:00Z")
        func r(_ s: String) -> String { RelativeTime.string(at(s), now: now, calendar: utc, locale: posix) }
        #expect(r("2026-09-24T14:05:30Z") == "just now")
        #expect(r("2026-09-24T14:04:00Z") == "2 min ago")
        #expect(r("2026-09-24T11:00:00Z") == "3 h ago")
        #expect(r("2026-09-23T20:00:00Z") == "Yesterday")
        #expect(r("2026-09-21T20:00:00Z") == "Mon")
        #expect(r("2026-09-02T20:00:00Z") == "Sep 2")
    }
}

func batch(_ items: [(String, String?, Committer.Outcome.Status, String?)], fallback: Bool = false) -> Watcher.Batch {
    var proposals: [Proposal] = []
    var outcomes: [Committer.Outcome] = []
    for (src, target, status, subject) in items {
        var p = Proposal(source: src, action: .rename, target: target)
        if let subject {
            p.tokens = ["subject": subject]
            var s = NameSuggestion(kind: .photo, subject: subject, confidence: 0.9, backend: fallback ? "vision" : "claude")
            if fallback { s.fallbackFrom = "claude: offline" }
            p.suggestion = s
        }
        proposals.append(p)
        outcomes.append(Committer.Outcome(source: src, target: target, status: status, message: status == .failed ? "disk full" : nil))
    }
    return Watcher.Batch(id: "b", proposals: proposals, outcomes: outcomes)
}

@Suite struct BatchMessageTests {
    @Test func threePhotos() {
        let m = BatchMessage.make(batch([
            ("/d/IMG_1.HEIC", "/d/2026-09-24_toronto_walnut-lamp-on-oak-sideboard.jpg", .done, "walnut-lamp-on-oak-sideboard"),
            ("/d/IMG_2.HEIC", "/d/2026-09-24_toronto_pothos-in-terracotta-pot.jpg", .done, "pothos-in-terracotta-pot"),
            ("/d/IMG_2.MOV", "/d/2026-09-24_toronto_pothos-in-terracotta-pot.mov", .done, nil),
            ("/d/IMG_3.HEIC", "/d/2026-09-24_toronto_cinema.jpg", .done, "cinema"),
        ]))
        #expect(m.title == "Renamed 3 photos")
        #expect(m.body == "walnut-lamp-on-oak-sideboard.jpg, pothos-in-terracotta-pot.jpg and 1 more")
        #expect(m.thumbnailPath == "/d/2026-09-24_toronto_walnut-lamp-on-oak-sideboard.jpg")
        #expect(!m.offline)
    }

    @Test func singleShowsTheFullName() {
        let m = BatchMessage.make(batch([("/d/IMG_1.HEIC", "/d/2026-09-24_toronto_cinema.jpg", .done, "cinema")]))
        #expect(m.title == "Renamed 1 photo")
        #expect(m.body == "2026-09-24_toronto_cinema.jpg")
    }

    @Test func offlineAndFailures() {
        let m = BatchMessage.make(batch([
            ("/d/a.HEIC", "/d/2026-09-24_window-brick.jpg", .done, "window-brick"),
            ("/d/b.HEIC", "/d/2026-09-24_drinking-glass.jpg", .done, "drinking-glass"),
            ("/d/c.HEIC", nil, .failed, nil),
        ], fallback: true))
        #expect(m.title == "Renamed 2 photos, 1 failed (offline)")
        #expect(m.body == "Claude couldn't be reached, so Apple Vision named these: window-brick.jpg and drinking-glass.jpg")
        let f = BatchMessage.make(batch([("/d/c.HEIC", nil, .failed, nil)]))
        #expect(f.title == "Couldn't rename 1 photo")
        #expect(f.body == "disk full")
        #expect(BatchMessage.undone(restored: 3).body == "Put back 3 originals with their old names.")
    }
}

@Suite struct RecentTests {
    @Test func newestPhotosFirstSkippingVideos() throws {
        let t = Temp()
        let j = Journal(url: t.url.appendingPathComponent("j.jsonl"))
        func add(_ batch: String, _ name: String, undo: Bool = false) throws {
            let r = JournalRecord(op: .begin, batch: batch, action: .rename, source: "/d/\(name)", target: "/d/new-\(name)", sourceSHA1: "a", outputSHA1: "a")
            try j.append(r); try j.append(r.with(.done))
            if undo { try j.append(r.with(.undo)) }
        }
        try add("b1", "1.HEIC"); try add("b1", "1.MOV")
        try add("b2", "2.HEIC"); try add("b2", "3.HEIC", undo: true)
        let items = Recent.items(j.recentBatches(), limit: 5)
        #expect(items.map(\.oldName) == ["3.HEIC", "2.HEIC", "1.HEIC"])
        #expect(items[0].undone && items[0].currentPath == "/d/3.HEIC")
        #expect(items[0].detail().hasPrefix("Put back · was new-3.HEIC"))
        #expect(items[1].detail(now: items[1].time.addingTimeInterval(120)) == "from 2.HEIC · 2 min ago")
        #expect(Recent.items(j.recentBatches(), limit: 2).count == 2)
        let last = try #require(Recent.lastUndoable(j.recentBatches()))
        #expect(last.id == "b2" && last.count == 1)
    }
}

@Suite struct EngineTests {
    @Test func status() {
        var c = Config()
        #expect(EngineStatus.current(config: c, hasCredential: true).name == "Claude Haiku 4.5")
        #expect(EngineStatus.current(config: c, hasCredential: false).name == "Apple Vision")
        #expect(EngineStatus.current(config: c, hasCredential: true, appleReady: true).name == "Apple Intelligence")
        c.claudeInAuto = false
        #expect(EngineStatus.current(config: c, hasCredential: true).name == "Apple Vision")
        c.backend = "claude"
        #expect(EngineStatus.current(config: c, hasCredential: false).detail == "Claude has no key")
        #expect(EngineStatus.modelName("claude-sonnet-4-5-20250929") == "Claude Sonnet 4.5")
        #expect(EngineStatus.modelName("gpt-x") == "gpt-x")
    }
}

@Suite struct CLILinkTests {
    @Test func installReplaceAndRemoveOnlyOurs() throws {
        let t = Temp()
        let app = t.url.appendingPathComponent("A/BetterAirdrop.app/Contents/Helpers/betterairdrop")
        let link = CLILink(home: t.url, target: app)
        #expect(link.status == .notInstalled)
        try link.install()
        #expect(link.status == .installed)
        // Another copy of the app: the old link is stale and gets replaced.
        let other = CLILink(home: t.url, target: t.url.appendingPathComponent("B/BetterAirdrop.app/Contents/Helpers/betterairdrop"))
        #expect(other.status == .stale(app.path))
        try other.install()
        #expect(other.status == .installed)
        #expect(other.remove())
        #expect(other.status == .notInstalled)
        // Something that isn't ours is never touched.
        try Data("#!/bin/sh\n".utf8).write(to: link.link)
        #expect(link.status == .foreign)
        #expect(!link.remove())
        #expect(throws: (any Error).self) { try link.install() }
        #expect(link.onPath("/usr/bin:\(t.url.path)/.local/bin"))
        #expect(!link.onPath("/usr/bin"))
    }
}

@Suite struct UninstallerTests {
    @Test func sequenceAndPurge() throws {
        let t = Temp()
        let support = t.url.appendingPathComponent("support"), config = t.url.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let link = CLILink(home: t.url, target: t.url.appendingPathComponent("X.app/Contents/Helpers/betterairdrop"))
        try link.install()
        var calls: [String] = []
        var u = Uninstaller()
        u.supportDirectory = support
        u.configDirectory = config
        u.cliLink = link
        u.unregisterLoginItem = { calls.append("unregister"); return true }
        u.deleteKeychainKey = { calls.append("keychain"); return true }
        u.run = { calls.append($0.joined(separator: " ")); return true }
        u.recycleApp = { calls.append("recycle"); return true }

        let steps = u.uninstall(purge: false)
        #expect(steps.allSatisfy { $0.ok })
        #expect(calls == ["unregister", "keychain", "/usr/bin/tccutil reset All dev.betterairdrop.app", "recycle"])
        #expect(link.status == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: support.path), "history is kept without purge")

        calls = []
        _ = u.uninstall(purge: true)
        #expect(!FileManager.default.fileExists(atPath: support.path))
        #expect(!FileManager.default.fileExists(atPath: config.path))
        #expect(calls.contains("/usr/bin/defaults delete dev.betterairdrop.app"))
        #expect(calls.last == "recycle", "the app goes to the Trash last")
    }
}

@Suite struct TemplatePreviewTests {
    @Test func rendersAndReportsErrors() throws {
        #expect(try TemplatePreview.render("{date}_{place}_{subject}").get() == "2026-09-24_toronto_walnut-lamp-on-oak-sideboard.jpg")
        #expect(throws: (any Error).self) { try TemplatePreview.render("{nope}").get() }
    }
}
