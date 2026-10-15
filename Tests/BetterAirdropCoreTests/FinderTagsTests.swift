@testable import BetterAirdropCore
import Foundation
import Testing

/// Finder tags (Pro): written on commit, recorded in the journal, and removed by undo.
@Suite struct FinderTagsTests {
    func committer(_ s: Sandbox, tagging: Bool = true) -> Committer {
        let c = s.committer()
        c.tagging = tagging
        return c
    }

    func planner(_ s: Sandbox, kind: Kind = .photo) -> Planner {
        var p = s.planner()
        p.namer = FakeNamer { _ in NameSuggestion(kind: kind, subject: "walnut lamp", confidence: 0.9, backend: "fake") }
        return p
    }

    @Test func photoGetsKindAndCityAndUndoRemovesThem() throws {
        let s = Sandbox()
        TestImages.jpeg(s.file("IMG_0001.jpg"))   // GPS: Toronto
        try FinderTags.add(["Family"], to: s.file("IMG_0001.jpg"))   // the user's own tag
        let p = planner(s).plan([s.file("IMG_0001.jpg")])
        let out = try committer(s).commit(p, batch: "t1")
        let renamed = URL(fileURLWithPath: out[0].target!)
        #expect(FinderTags.read(renamed) == ["Family", "Photo", "Toronto"])
        #expect(s.journal.entries()[0].latest.tags == ["Photo", "Toronto"])

        _ = try s.undoer().undo(.batch("t1"))
        #expect(FinderTags.read(s.file("IMG_0001.jpg")) == ["Family"])
    }

    @Test func tagsDontChangeTheFileSoUndoStillMatches() throws {
        let s = Sandbox()
        TestImages.png(s.file("IMG_0002.png"))
        let before = try Data(contentsOf: s.file("IMG_0002.png"))
        let out = try committer(s).commit(planner(s, kind: .receipt).plan([s.file("IMG_0002.png")]), batch: "t2")
        #expect(FinderTags.read(URL(fileURLWithPath: out[0].target!)) == ["Receipt"])   // no city for a receipt
        #expect(try Data(contentsOf: URL(fileURLWithPath: out[0].target!)) == before)
        let undone = try s.undoer().undo(.last)
        #expect(undone.map(\.status) == [.restored])
        #expect(FinderTags.read(s.file("IMG_0002.png")).isEmpty)
    }

    @Test func convertedJPEGIsTaggedAndUndoRestoresTheUntaggedOriginal() throws {
        let s = Sandbox()
        TestImages.heic(s.file("IMG_0003.HEIC"))
        let out = try committer(s).commit(planner(s, kind: .screenshot).plan([s.file("IMG_0003.HEIC")]), batch: "t3")
        #expect(FinderTags.read(URL(fileURLWithPath: out[0].target!)) == ["Screenshot"])
        _ = try s.undoer().undo(.last)
        #expect(s.listing() == ["IMG_0003.HEIC"])
        #expect(FinderTags.read(s.file("IMG_0003.HEIC")).isEmpty)
    }

    @Test func offByDefault() throws {
        let s = Sandbox()
        TestImages.jpeg(s.file("IMG_0004.jpg"))
        let out = try s.committer().commit(planner(s).plan([s.file("IMG_0004.jpg")]), batch: "t4")
        #expect(FinderTags.read(URL(fileURLWithPath: out[0].target!)).isEmpty)
        #expect(s.journal.entries()[0].latest.tags == nil)
    }

    @Test func existingTagIsNotAddedTwiceOrRemovedByUndo() throws {
        let s = Sandbox()
        TestImages.jpeg(s.file("IMG_0005.jpg"))
        try FinderTags.add(["photo"], to: s.file("IMG_0005.jpg"))
        _ = try committer(s).commit(planner(s).plan([s.file("IMG_0005.jpg")]), batch: "t5")
        #expect(s.journal.entries()[0].latest.tags == ["Toronto"])
        _ = try s.undoer().undo(.last)
        #expect(FinderTags.read(s.file("IMG_0005.jpg")) == ["photo"])
    }

    @Test func config() throws {
        #expect(try Config.parse("finder_tags = true").finderTags)
        #expect(!Config().finderTags && !Config().rendered(updating: nil).contains("finder_tags"))
    }
}
