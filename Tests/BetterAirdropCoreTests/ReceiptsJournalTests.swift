@testable import BetterAirdropCore
import Foundation
import Testing

/// The journal keeps what was read off a receipt, for "Export Receipts as CSV" (Pro).
@Suite struct ReceiptsJournalTests {
    @Test func receiptFieldsAreJournaled() throws {
        let s = Sandbox()
        TestImages.png(s.file("IMG_R009.png"))
        TestImages.png(s.file("IMG_0009.png"))
        var p = s.planner()
        p.namer = FakeNamer { ctx in
            ctx.file.hasSuffix("IMG_R009.png")
                ? NameSuggestion(kind: .receipt, subject: "grocery receipt", merchant: "Loblaws", total: "84.12", confidence: 0.9, backend: "fake")
                : NameSuggestion(kind: .photo, subject: "walnut lamp", confidence: 0.9, backend: "fake")
        }
        _ = try s.committer().commit(p.plan([s.file("IMG_R009.png"), s.file("IMG_0009.png")]), batch: "r1")
        let e = s.journal.entries()
        #expect(e[0].begin.receipt == .init(date: "2026-09-21", merchant: "Loblaws", total: "84.12"))
        #expect(e[1].begin.receipt == nil)
    }
}
