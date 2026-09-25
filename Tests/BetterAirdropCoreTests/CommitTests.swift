@testable import BetterAirdropCore
import Foundation
import ImageIO
import Testing

/// A scratch "Downloads" with its own journal and fake Trash.
final class Sandbox {
    let root = TestImages.TempDir()
    var downloads: URL { root.path("Downloads") }
    var trashDir: URL { root.path("Trash") }
    let journal: Journal
    let trash: DirectoryTrash
    let places = try! Places(packed: Places.pack(geonamesTSV: TestImages.geonamesSample))

    init() {
        try! FileManager.default.createDirectory(at: root.path("Downloads"), withIntermediateDirectories: true)
        journal = Journal(url: root.path("state/journal.jsonl"))
        trash = DirectoryTrash(root.path("Trash"))
    }

    func file(_ name: String) -> URL { downloads.appendingPathComponent(name) }

    func listing() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).sorted()
    }

    func snapshot() -> [String: Data] {
        Dictionary(uniqueKeysWithValues: listing().map { ($0, try! Data(contentsOf: file($0))) })
    }

    func planner(_ config: Config = Config()) -> Planner { Planner(config: config, places: places) }
    func committer(_ config: Config = Config()) -> Committer { Committer(config: config, journal: journal, trasher: trash) }
    func undoer() -> Undoer { Undoer(journal: journal, trasher: trash) }

    /// Plans and commits every file currently in Downloads.
    @discardableResult
    func run(_ config: Config = Config(), fault: ((Committer.Stage, URL) throws -> Void)? = nil) throws -> [Committer.Outcome] {
        let urls = listing().map(file)
        let c = committer(config)
        c.fault = fault
        return try c.commit(planner(config).plan(urls))
    }

    /// Three typical arrivals: a HEIC with GPS, a screenshot PNG and a JPEG.
    func populate() {
        TestImages.heic(file("IMG_4821.HEIC"), .init(dateTimeOriginal: "2026:09:21 14:03:10", offset: "-04:00", gps: (43.6532, -79.3832), orientation: 6), seed: 1)
        TestImages.png(file("IMG_4822.PNG"), .init(gps: nil, userComment: "Screenshot"), seed: 2)
        TestImages.jpeg(file("IMG_4823.JPG"), .init(dateTimeOriginal: "2026:07:01 00:30:00", offset: "+01:00", gps: (38.7223, -9.1393)), seed: 3)
    }
}

@Suite struct ConverterTests {
    /// PLAN.md §5: DateTimeOriginal, OffsetTime, GPS, Make/Model and orientation survive conversion.
    @Test func metadataGolden() throws {
        let dir = TestImages.TempDir()
        let src = TestImages.heic(dir.path("in.HEIC"), .init(dateTimeOriginal: "2026:09:21 14:03:10", offset: "-04:00",
                                                             gps: (43.6532, -79.3832), make: "Apple", model: "iPhone 15 Pro", orientation: 6))
        let out = dir.path("out.jpg")
        try Converter.toJPEG(source: src, destination: out, quality: 0.88)
        let before = try PhotoMetadata.read(src), after = try PhotoMetadata.read(out)
        #expect(after.uti == "public.jpeg")
        #expect(after.date == before.date && after.date == "2026-09-21")
        #expect(after.time == "1403")
        #expect(after.offset == "-04:00")
        #expect(abs(after.latitude! - 43.6532) < 1e-4 && abs(after.longitude! - -79.3832) < 1e-4)
        #expect(after.make == "Apple" && after.model == "iPhone 15 Pro")
        #expect(after.orientation == 6)
        #expect(after.pixelWidth == before.pixelWidth && after.pixelHeight == before.pixelHeight)
    }

    @Test func stripGPS() throws {
        let dir = TestImages.TempDir()
        let src = TestImages.heic(dir.path("in.HEIC"))
        let out = dir.path("out.jpg")
        try Converter.toJPEG(source: src, destination: out, quality: 0.8, stripGPS: true)
        let m = try PhotoMetadata.read(out)
        #expect(!m.hasGPS)
        #expect(m.date == "2026-09-21")
    }

    @Test func truncatedSourceIsRejected() throws {
        let dir = TestImages.TempDir()
        let src = TestImages.heic(dir.path("in.HEIC"))
        let data = try Data(contentsOf: src)
        try data.prefix(data.count / 2).write(to: src)
        #expect(throws: (any Error).self) { try Converter.toJPEG(source: src, destination: dir.path("out.jpg"), quality: 0.8) }
        #expect(!FileManager.default.fileExists(atPath: dir.path("out.jpg").path))
        #expect(Planner(config: Config(), places: nil).skipReason(src) == "incomplete image file")
    }

    @Test(arguments: ["heic", "jpg", "png"])
    func integrityCheck(ext: String) throws {
        let dir = TestImages.TempDir()
        let url = TestImages.write(dir.path("a.\(ext)"), type: ext == "heic" ? .heic : ext == "jpg" ? .jpeg : .png)
        #expect(ImageIntegrity.isComplete(url))
        let data = try Data(contentsOf: url)
        for cut in [data.count - 1, data.count * 3 / 4, 40] {
            try data.prefix(cut).write(to: url)
            #expect(!ImageIntegrity.isComplete(url), "\(ext) cut at \(cut)/\(data.count)")
        }
    }
}

@Suite struct CommitTests {
    @Test func convertsRenamesAndJournals() throws {
        let s = Sandbox(); s.populate()
        let out = try s.run()
        #expect(out.map(\.status) == [.done, .done, .done])
        #expect(s.listing() == ["2026-07-01_lisbon_img-4823.jpg", "2026-09-21_screenshot_img-4822.png", "2026-09-21_toronto_img-4821.jpg"])
        // The HEIC went to the (fake) Trash; the JPEG output carries the marker.
        #expect((try FileManager.default.contentsOfDirectory(atPath: s.trashDir.path)) == ["IMG_4821.HEIC"])
        #expect(Marker.read(s.file("2026-09-21_toronto_img-4821.jpg")) != nil)
        #expect(try PhotoMetadata.read(s.file("2026-09-21_toronto_img-4821.jpg")).uti == "public.jpeg")
        let recs = s.journal.records()
        #expect(recs.map(\.op) == [.begin, .done, .begin, .done, .begin, .done])
        #expect(recs[1].trashed?.hasSuffix("Trash/IMG_4821.HEIC") == true)
        #expect(Set(recs.map(\.batch)).count == 1)
    }

    @Test func secondRunIsANoOp() throws {
        let s = Sandbox(); s.populate()
        try s.run()
        let after = s.snapshot()
        let journalCount = s.journal.records().count
        let second = try s.run()
        #expect(second.allSatisfy { $0.status == .skipped })
        #expect(s.snapshot() == after)
        #expect(s.journal.records().count == journalCount)
    }

    @Test func undoRestoresByteIdenticalFiles() throws {
        let s = Sandbox(); s.populate()
        let before = s.snapshot()
        try s.run()
        #expect(s.snapshot() != before)
        let undone = try s.undoer().undo(.last)
        #expect(undone.map(\.status) == [.restored, .restored, .restored])
        #expect(s.snapshot() == before)
        #expect(s.listing().allSatisfy { Marker.read(s.file($0)) == nil })
        #expect((try FileManager.default.contentsOfDirectory(atPath: s.trashDir.path)).isEmpty)
        // Nothing left to undo, and the originals are processable again.
        #expect(throws: Undoer.Error.self) { try s.undoer().undo(.last) }
        #expect(try s.run().allSatisfy { $0.status == .done })
    }

    @Test func undoSingleFileAndByBatch() throws {
        let s = Sandbox(); s.populate()
        try s.run()
        let batch = try #require(s.journal.records().first?.batch)
        let one = try s.undoer().undo(.file(s.file("2026-09-21_screenshot_img-4822.png").path))
        #expect(one.count == 1 && one[0].status == .restored)
        #expect(s.listing().contains("IMG_4822.PNG"))
        let rest = try s.undoer().undo(.batch(batch))
        #expect(rest.count == 2)
        #expect(s.listing() == ["IMG_4821.HEIC", "IMG_4822.PNG", "IMG_4823.JPG"])
    }

    @Test func undoRefusesEditedOutputUnlessForced() throws {
        let s = Sandbox()
        TestImages.jpeg(s.file("IMG_1.JPG"))
        try s.run()
        let out = s.file("2026-09-21_toronto_img-1.jpg")
        try Data("edited".utf8).write(to: out)
        #expect(try s.undoer().undo(.last).map(\.status) == [.refused])
        #expect(s.listing() == ["2026-09-21_toronto_img-1.jpg"])
        var u = s.undoer(); u.force = true
        #expect(try u.undo(.last).map(\.status) == [.restored])
        #expect(s.listing() == ["IMG_1.JPG"])
    }

    @Test func originalsKeepAndDelete() throws {
        let s = Sandbox()
        TestImages.heic(s.file("IMG_1.HEIC"))
        var c = Config(); c.originals = .keep
        try s.run(c)
        #expect(s.listing() == ["2026-09-21_toronto_img-1.jpg", "IMG_1.HEIC"])
        // The kept original is marked, so a second run doesn't convert it again.
        #expect(try s.run(c).allSatisfy { $0.status == .skipped })
        #expect(try s.undoer().undo(.last).map(\.status) == [.restored])
        #expect(s.listing() == ["IMG_1.HEIC"])
        #expect(Marker.read(s.file("IMG_1.HEIC")) == nil)
        c.originals = .delete
        try s.run(c)
        #expect(s.listing() == ["2026-09-21_toronto_img-1.jpg"])
        #expect(try s.undoer().undo(.last).map(\.status) == [.failed])   // honest: nothing to restore
        #expect(s.listing() == ["2026-09-21_toronto_img-1.jpg"])        // output left in place
    }

    @Test func raceForTheTargetNameNeverOverwrites() throws {
        let s = Sandbox()
        TestImages.jpeg(s.file("IMG_1.JPG"))
        let plan = s.planner().plan([s.file("IMG_1.JPG")])
        // Something else claims the name between planning and committing.
        try Data("someone else's".utf8).write(to: s.file("2026-09-21_toronto_img-1.jpg"))
        let out = try s.committer().commit(plan)
        #expect(out[0].status == .done)
        #expect(s.listing() == ["2026-09-21_toronto_img-1-2.jpg", "2026-09-21_toronto_img-1.jpg"])
        #expect(try Data(contentsOf: s.file("2026-09-21_toronto_img-1.jpg")) == Data("someone else's".utf8))
        _ = try s.undoer().undo(.last)
        #expect(s.listing() == ["2026-09-21_toronto_img-1.jpg", "IMG_1.JPG"])
    }

    @Test func errorsRollBackAndLeaveTheSourceUntouched() throws {
        struct Boom: Error {}
        for stage in Committer.Stage.allCases {
            let s = Sandbox(); s.populate()
            let before = s.snapshot()
            let out = try s.run { st, url in if st == stage && url.lastPathComponent == "IMG_4821.HEIC" { throw Boom() } }
            #expect(out.map(\.status) == [.failed, .done, .done], "stage \(stage)")
            // The failed HEIC is untouched and nothing it produced remains.
            #expect(s.snapshot()["IMG_4821.HEIC"] == before["IMG_4821.HEIC"], "stage \(stage)")
            #expect(!s.listing().contains { $0.contains("img-4821") || $0.hasSuffix(".tmp") }, "stage \(stage)")
            let states = s.journal.entries().filter { $0.begin.source.hasSuffix("IMG_4821.HEIC") }.map(\.state)
            #expect(states == (stage == .tempWritten ? [] : [.error]), "stage \(stage)")
        }
    }

    /// PLAN.md §6.3: a crash between any two steps loses nothing, and `undo` gets back to the start.
    @Test(arguments: Committer.Stage.allCases, ["IMG_4821.HEIC", "IMG_4822.PNG"])
    func crashAtEveryStageIsRecoverable(stage: Committer.Stage, victim: String) throws {
        if stage == .tempWritten && victim.hasSuffix(".PNG") { return }   // plain renames have no temp file
        let s = Sandbox(); s.populate()
        let before = s.snapshot()
        #expect(throws: Committer.SimulatedCrash.self) {
            try s.run { st, url in if st == stage && url.lastPathComponent == victim { throw Committer.SimulatedCrash() } }
        }
        // Recover: undo whatever the journal knows about, then sweep temp files as the next run would.
        if !s.undoer().pending().isEmpty {
            let r = try s.undoer().undo(.last)
            #expect(r.allSatisfy { $0.status == .restored || $0.status == .alreadyClean }, "\(stage) \(victim): \(r)")
        }
        Committer.sweepTemporaries(in: s.downloads, olderThan: -1)
        #expect(s.snapshot() == before, "\(stage) \(victim)")
        #expect(s.listing().allSatisfy { Marker.read(s.file($0)) == nil })
    }

    @Test func journalSurvivesGarbageLines() throws {
        let s = Sandbox()
        TestImages.jpeg(s.file("IMG_1.JPG"))
        try s.run()
        let h = try FileHandle(forWritingTo: s.journal.url)
        h.seekToEndOfFile(); h.write(Data("{not json\n".utf8)); try h.close()
        #expect(s.journal.records().count == 2)
        #expect(s.journal.entries().map(\.state) == [.done])
    }
}
