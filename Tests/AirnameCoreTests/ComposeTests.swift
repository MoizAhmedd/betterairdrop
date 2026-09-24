@testable import AirnameCore
import Foundation
import Testing

@Suite struct SlugTests {
    @Test func foldsDiacriticsAndCase() {
        #expect(Slug.make("Montréal") == "montreal")
        #expect(Slug.make("Straße in Köln", trimStopWords: false) == "strasse-in-koln")
        #expect(Slug.make("São Paulo") == "sao-paulo")
    }

    @Test func trimsStopWordsButNeverToNothing() {
        #expect(Slug.make("A lamp on the oak sideboard") == "lamp-oak-sideboard")
        #expect(Slug.make("the") == "the")
    }

    @Test func separatorsAndPunctuation() {
        #expect(Slug.make("  walnut_lamp // oak...sideboard!! ") == "walnut-lamp-oak-sideboard")
        #expect(Slug.make("Sam's desk") == "sams-desk")
        #expect(Slug.make("🎉 party 🎉") == "party")
        #expect(Slug.make("東京") == "dong-jing")   // transliterated, not dropped
    }

    @Test func caps() {
        #expect(Slug.make("one two three four five six seven", maxWords: 6) == "one-two-three-four-five-six")
        #expect(Slug.make("alpha beta gamma", maxChars: 12) == "alpha-beta")
        #expect(Slug.make("supercalifragilistic", maxChars: 5) == "super")
    }

    @Test func noLeadingDotsOrSlashes() {
        #expect(Slug.make("../../etc/passwd") == "etc-passwd")
        #expect(Slug.make(".hidden") == "hidden")
    }
}

@Suite struct TemplateTests {
    let full = ["date": "2026-09-21", "place": "toronto", "subject": "walnut-lamp", "orig": "img-4821", "kind": "photo"]

    @Test func renders() throws {
        #expect(try Template("{date}_{place}_{subject}").render(full) == "2026-09-21_toronto_walnut-lamp")
    }

    @Test func emptyTokensCollapse() throws {
        var v = full; v["place"] = ""
        #expect(try Template("{date}_{place}_{subject}").render(v) == "2026-09-21_walnut-lamp")
        v["date"] = ""
        #expect(try Template("{date}_{place}_{subject}").render(v) == "walnut-lamp")
        #expect(try Template("{date}-{time}-{subject}").render(v) == "walnut-lamp")
    }

    @Test func perKindLiterals() throws {
        let v = ["date": "2026-09-21", "merchant": "loblaws", "total": "84-12"]
        #expect(try Template("{date}_receipt_{merchant}_{total}").render(v) == "2026-09-21_receipt_loblaws_84-12")
        #expect(try Template("{date}_receipt_{merchant}_{total}").render(["date": "2026-09-21", "total": "5-00"]) == "2026-09-21_receipt_5-00")
    }

    @Test func refusesDateOnlyNames() throws {
        #expect(try Template("{date}_{subject}").render(["date": "2026-09-21"]) == nil)
        #expect(Template.fallback.render(["date": "2026-09-21", "orig": "img-4821"]) == "2026-09-21_img-4821")
    }

    @Test func validation() {
        #expect(throws: Template.Error.unknownToken("colour")) { try Template("{date}_{colour}") }
        #expect(throws: Template.Error.unclosedBrace) { try Template("{date}_{subject") }
        #expect(throws: Template.Error.noDescriptiveToken) { try Template("{date}_{place}") }
    }

    @Test func literalsCantEscapeTheFolder() throws {
        #expect(try Template("../{subject}").render(full) == "walnut-lamp")
        #expect(try Template("a/b_{subject}").render(full) == "a-b_walnut-lamp")
    }

    @Test func capsTotalLength() throws {
        let long = Array(repeating: "word", count: 40).joined(separator: "-")
        let s = try #require(try Template("{date}_{subject}").render(["date": "2026-09-21", "subject": long]))
        #expect(s.count <= Template.maxLength)
        #expect(!s.hasSuffix("-"))
    }
}

@Suite struct CollisionTests {
    @Test func appendsCounters() throws {
        let dir = TestImages.TempDir()
        FileManager.default.createFile(atPath: dir.path("a.jpg").path, contents: Data())
        FileManager.default.createFile(atPath: dir.path("a-2.jpg").path, contents: Data())
        #expect(CollisionResolver.resolve(directory: dir.url, stem: "a", ext: "jpg").lastPathComponent == "a-3.jpg")
        #expect(CollisionResolver.resolve(directory: dir.url, stem: "b", ext: "jpg").lastPathComponent == "b.jpg")
        // Reservations from earlier files in the batch count, case-insensitively.
        let reserved: Set = [dir.path("b.jpg").path.lowercased()]
        #expect(CollisionResolver.resolve(directory: dir.url, stem: "B", ext: "jpg", reserved: reserved).lastPathComponent == "B-2.jpg")
    }
}
