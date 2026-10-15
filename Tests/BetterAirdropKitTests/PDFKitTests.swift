@testable import BetterAirdropCore
@testable import BetterAirdropKit
import Foundation
import Testing

/// The app-side pieces of "Name PDFs too" (Pro): which watchers take PDFs, folder drops, the banner
/// text and the receipts export.
@Suite struct PDFProTests {
    @Test func watchPlanGivesPDFsToTheAirDropAndOtherFoldersOnly() {
        let dl = URL(fileURLWithPath: "/Users/me/Downloads"), shots = URL(fileURLWithPath: "/Users/me/Desktop")
        let inbox = URL(fileURLWithPath: "/Users/me/Inbox")
        let on = WatchPlan.make(main: dl, mainAirdropOnly: true, screenshots: shots, extras: [inbox], pdfs: true)
        #expect(on.entries.map(\.role) == [.airdrop, .screenshots, .folder])
        #expect(on.entries.map(\.pdfs) == [true, false, true])
        // Only the added folder takes every new PDF; the AirDrop folder keeps the downloaded-only rule, switch or not.
        #expect(on.entries.map(\.everyPDF) == [false, false, true])
        #expect(WatchPlan.make(main: dl, mainAirdropOnly: false, screenshots: nil, extras: [], pdfs: true).entries.map(\.everyPDF) == [false])
        let off = WatchPlan.make(main: dl, mainAirdropOnly: true, screenshots: shots, extras: [inbox])
        #expect(off.entries.allSatisfy { !$0.pdfs })
    }

    @Test func foldersAndDropsIncludePDFsOnlyWhenOn() throws {
        let t = Temp()
        let fm = FileManager.default
        for p in ["a/IMG_1.HEIC", "a/bill.pdf", "a/sub/scan.PDF", "a/Tool.app/Contents/manual.pdf", "a/notes.txt"] {
            let u = t.url.appendingPathComponent(p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data("x".utf8))
        }
        let a = t.url.appendingPathComponent("a")
        let base = a.resolvingSymlinksInPath().path + "/"
        func rel(_ us: [URL]) -> [String] { us.map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") } }
        #expect(rel(PhotoFolders.images(in: a)) == ["IMG_1.HEIC"])
        #expect(rel(PhotoFolders.images(in: a, pdfs: true)) == ["IMG_1.HEIC", "bill.pdf", "sub/scan.PDF"])
        let dropped = [a.appendingPathComponent("IMG_1.HEIC"), a.appendingPathComponent("bill.pdf")]
        let free = PhotoFolders.split(dropped)
        #expect(free.files.map(\.lastPathComponent) == ["IMG_1.HEIC"] && free.skippedPDFs == 1)
        let pro = PhotoFolders.split(dropped, pdfs: true)
        #expect(pro.files.map(\.lastPathComponent) == ["IMG_1.HEIC", "bill.pdf"] && pro.skippedPDFs == 0)
    }

    @Test func bannerSaysPDF() {
        let one = BatchMessage.make(batch([("/d/document (3).pdf", "/d/2026-10-12_invoice_bell-canada_84-12.pdf", .done, "internet-tv-bill")]))
        #expect(one.title == "Renamed 1 PDF")
        #expect(one.body == "2026-10-12_invoice_bell-canada_84-12.pdf")
        #expect(one.thumbnailPath == nil)   // notification attachments are images
        let mixed = BatchMessage.make(batch([
            ("/d/IMG_1.HEIC", "/d/2026-09-24_toronto_lamp.jpg", .done, "lamp"),
            ("/d/scan0004.pdf", "/d/2026-09-30_lease-agreement.pdf", .done, "lease-agreement"),
        ]))
        #expect(mixed.title == "Renamed 1 photo and 1 PDF")
        #expect(mixed.thumbnailPath == "/d/2026-09-24_toronto_lamp.jpg")
        #expect(BatchMessage.make(batch([("/d/x.pdf", nil, .failed, nil)])).title == "Couldn't rename 1 PDF")
    }

    @Test func receiptsCSVIncludesPDFReceiptsAndInvoices() throws {
        let t = Temp()
        let j = Journal(url: t.url.appendingPathComponent("journal.jsonl"))
        func add(_ source: String, _ target: String, summary: String, receipt: JournalRecord.ReceiptFields?) throws {
            var r = JournalRecord(op: .begin, batch: "b", action: .rename, source: source, target: target, sourceSHA1: "a", outputSHA1: "a", summary: summary)
            r.receipt = receipt
            try j.append(r)
            try j.append(r.with(.done))
        }
        try add("/d/document (3).pdf", "/d/2026-10-12_invoice_bell-canada_84-12.pdf", summary: "invoice: internet and tv bill",
                receipt: .init(date: "2026-10-12", merchant: "Bell Canada", total: "84-12"))
        try add("/d/order.pdf", "/d/2026-10-01_receipt_amazon_42-00.pdf", summary: "receipt: online order",
                receipt: .init(date: "2026-10-01", merchant: "Amazon", total: "42-00"))
        try add("/d/lease.pdf", "/d/2026-09-30_lease-agreement.pdf", summary: "contract: lease agreement", receipt: nil)
        let rows = ReceiptsCSV.rows(j.entries())
        #expect(rows.map(\.file) == ["/d/2026-10-01_receipt_amazon_42-00.pdf", "/d/2026-10-12_invoice_bell-canada_84-12.pdf"])
        #expect(ReceiptsCSV.make(j.entries()).hasPrefix(ReceiptsCSV.header + "\r\n2026-10-01,Amazon,42-00,"))
    }
}
