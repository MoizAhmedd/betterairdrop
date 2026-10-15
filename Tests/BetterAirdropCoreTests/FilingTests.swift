@testable import BetterAirdropCore
import Foundation
import Testing

/// Auto-file by kind (Pro): the move is part of the rename, so it's journaled and undone with it.
@Suite struct FilingTests {
    let receiptNamer = FakeNamer { ctx in
        let stem = URL(fileURLWithPath: ctx.file).deletingPathExtension().lastPathComponent
        if stem.hasPrefix("IMG_R") { return NameSuggestion(kind: .receipt, subject: "grocery receipt", merchant: "Loblaws", total: "84.12", confidence: 0.9, backend: "fake") }
        return NameSuggestion(kind: .photo, subject: "walnut lamp", confidence: 0.9, backend: "fake")
    }

    func filed(_ s: Sandbox, monthly: Bool = true) -> (Planner, URL) {
        let receipts = s.root.path("Documents/Receipts")
        var p = s.planner()
        p.namer = receiptNamer
        p.filing = Filing(folders: [.receipt: receipts], monthly: monthly)
        return (p, receipts)
    }

    func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    @Test func receiptsGoToTheirMonthFolderAndUndoBringsThemBack() throws {
        let s = Sandbox()
        TestImages.heic(s.file("IMG_R001.HEIC"))       // EXIF date 2026-09-21
        TestImages.jpeg(s.file("IMG_0002.jpg"))        // a photo: no rule, stays
        let (planner, receipts) = filed(s)
        let proposals = planner.plan([s.file("IMG_R001.HEIC"), s.file("IMG_0002.jpg")])
        #expect(proposals[0].target == receipts.appendingPathComponent("2026-09/2026-09-21_receipt_loblaws_84-12.jpg").path)
        #expect(proposals[1].target == s.file("2026-09-21_toronto_walnut-lamp.jpg").path)

        let outcomes = try s.committer().commit(proposals, batch: "b1")
        #expect(outcomes.map(\.status) == [.done, .done])
        #expect(listing(receipts.appendingPathComponent("2026-09")) == ["2026-09-21_receipt_loblaws_84-12.jpg"])
        #expect(s.listing() == ["2026-09-21_toronto_walnut-lamp.jpg"])   // the HEIC original went to the Trash
        #expect(s.journal.entries().first?.latest.target == receipts.appendingPathComponent("2026-09/2026-09-21_receipt_loblaws_84-12.jpg").path)

        let undone = try s.undoer().undo(.batch("b1"))
        #expect(undone.map(\.status) == [.restored, .restored])
        #expect(s.listing() == ["IMG_0002.jpg", "IMG_R001.HEIC"])
        #expect(listing(receipts.appendingPathComponent("2026-09")).isEmpty)
    }

    @Test func plainRenameMovesAndUndoesWithoutMonthFolders() throws {
        let s = Sandbox()
        TestImages.png(s.file("IMG_R002.png"))
        let (planner, receipts) = filed(s, monthly: false)
        let p = planner.plan([s.file("IMG_R002.png")])
        #expect(p[0].action == .rename)
        _ = try s.committer().commit(p, batch: "b2")
        #expect(listing(receipts) == ["2026-09-21_receipt_loblaws_84-12.png"])
        #expect(s.listing().isEmpty)
        _ = try s.undoer().undo(.last)
        #expect(s.listing() == ["IMG_R002.png"])
        #expect(listing(receipts).isEmpty)
    }

    @Test func collisionsInTheDestinationGetASuffix() throws {
        let s = Sandbox()
        let (planner, receipts) = filed(s)
        try FileManager.default.createDirectory(at: receipts.appendingPathComponent("2026-09"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: receipts.appendingPathComponent("2026-09/2026-09-21_receipt_loblaws_84-12.png"))
        TestImages.png(s.file("IMG_R003.png"))
        let p = planner.plan([s.file("IMG_R003.png")])
        #expect(p[0].target?.hasSuffix("2026-09/2026-09-21_receipt_loblaws_84-12-2.png") == true)
    }

    @Test func aLivePhotoVideoFollowsItsStill() throws {
        let s = Sandbox()
        var (planner, receipts) = filed(s)
        planner.filing = Filing(folders: [.photo: receipts], monthly: true)   // file photos this time
        TestImages.heic(s.file("IMG_0007.HEIC")); AirDropSim.tag(s.file("IMG_0007.HEIC"))
        try Data("mov".utf8).write(to: s.file("IMG_0007.MOV")); AirDropSim.tag(s.file("IMG_0007.MOV"))
        var o = Watcher.Options(folder: s.downloads)
        o.backlog = true
        let w = Watcher(options: o, planner: planner, committer: s.committer())
        let b = w.process([s.file("IMG_0007.HEIC"), s.file("IMG_0007.MOV")])
        #expect(b.outcomes.map(\.status) == [.done, .done])
        #expect(listing(receipts.appendingPathComponent("2026-09")) == ["2026-09-21_toronto_walnut-lamp.jpg", "2026-09-21_toronto_walnut-lamp.mov"])
    }

    @Test func withoutFilingNothingMoves() throws {
        let s = Sandbox()
        TestImages.png(s.file("IMG_R004.png"))
        var p = s.planner()
        p.namer = receiptNamer
        #expect(p.plan([s.file("IMG_R004.png")])[0].target == s.file("2026-09-21_receipt_loblaws_84-12.png").path)
    }

    @Test func monthFolders() {
        let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
        let f = Filing(folders: [.receipt: URL(fileURLWithPath: "/R")])
        #expect(f.directory(for: .receipt, date: "2026-09-21", now: now)?.path == "/R/2026-09")
        #expect(f.directory(for: .receipt, date: nil, now: now)?.path == "/R/2026-10")
        #expect(f.directory(for: .photo, date: "2026-09-21", now: now) == nil)
        #expect(Filing(folders: [.receipt: URL(fileURLWithPath: "/R")], monthly: false).directory(for: .receipt, date: "2026-09-21")?.path == "/R")
    }

    @Test func config() throws {
        let c = try Config.parse("[file]\nreceipt = \"~/Documents/Receipts\"\nscreenshot = \"\"\nmonthly = false\n")
        #expect(c.fileFolders == ["receipt": "~/Documents/Receipts"])
        #expect(!c.fileMonthly)
        #expect(try Config.parse(c.rendered(updating: nil)) == c)
        let f = Filing(config: c, home: URL(fileURLWithPath: "/Users/t"))
        #expect(f == Filing(folders: [.receipt: URL(fileURLWithPath: "/Users/t/Documents/Receipts")], monthly: false))
        #expect(Filing(config: Config()) == nil)
        #expect(throws: Config.ParseError.self) { try Config.parse("[file]\nbananas = \"~/x\"") }
        #expect(!Config().rendered(updating: nil).contains("[file]"))
    }
}
