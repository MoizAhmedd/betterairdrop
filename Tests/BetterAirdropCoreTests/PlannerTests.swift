@testable import BetterAirdropCore
import Foundation
import Testing

/// Golden dry-run tests: the deterministic fields (date, place, target shape) for synthetic
/// stand-ins of PLAN.md §6 fixtures 1–5 and 20.
@Suite struct PlannerTests {
    let places = try! Places(packed: Places.pack(geonamesTSV: TestImages.geonamesSample))

    func planner(_ config: Config = Config()) -> Planner { Planner(config: config, places: places) }

    func names(_ ps: [Proposal]) -> [String] { ps.map { ($0.target.map { ($0 as NSString).lastPathComponent }) ?? "skip: \($0.reason ?? "")" } }

    @Test func goldenFixtures() throws {
        let dir = TestImages.TempDir()
        let files = [
            TestImages.heic(dir.path("IMG_0001.HEIC"), .init(dateTimeOriginal: "2026:09:21 10:00:00", gps: (43.6532, -79.3832)), seed: 1),
            TestImages.heic(dir.path("IMG_0002.HEIC"), .init(dateTimeOriginal: "2026:09:21 11:00:00", gps: (43.6450, -79.3900)), seed: 2),
            TestImages.heic(dir.path("IMG_0003.HEIC"), .init(dateTimeOriginal: "2026:09:22 12:00:00", gps: (45.5017, -73.5673)), seed: 3),
            TestImages.heic(dir.path("IMG_0004.HEIC"), .init(dateTimeOriginal: "2026:09:23 13:00:00", gps: nil), seed: 4),
            TestImages.heic(dir.path("IMG_0005.HEIC"), .init(dateTimeOriginal: "2026:09:24 14:00:00", orientation: 6), seed: 5),
            // Lisbon, just after midnight local time: the date must be Lisbon's, not the Mac's.
            TestImages.heic(dir.path("IMG_0020.HEIC"), .init(dateTimeOriginal: "2026:07:01 00:30:00", offset: "+01:00", gps: (38.7223, -9.1393)), seed: 20),
        ]
        let plan = planner().plan(files)
        #expect(names(plan) == [
            "2026-09-21_toronto_img-0001.jpg",
            "2026-09-21_toronto_img-0002.jpg",
            "2026-09-22_montreal_img-0003.jpg",
            "2026-09-23_img-0004.jpg",
            "2026-09-24_toronto_img-0005.jpg",
            "2026-07-01_lisbon_img-0020.jpg",
        ])
        #expect(plan.allSatisfy { $0.action == .convert })
        #expect(plan[5].context?.place?.countryCode == "PT")
    }

    @Test func nonHEICIsRenamedNotConverted() throws {
        let dir = TestImages.TempDir()
        let png = TestImages.png(dir.path("IMG_0008.PNG"), .init(gps: nil, userComment: "Screenshot"))
        let jpg = TestImages.jpeg(dir.path("IMG_0012.JPEG"))
        let plan = planner().plan([png, jpg])
        #expect(plan.map(\.action) == [.rename, .rename])
        #expect(names(plan) == ["2026-09-21_screenshot_img-0008.png", "2026-09-21_toronto_img-0012.jpg"])
        #expect(plan[0].context?.kind == .screenshot)
    }

    @Test func convertCanBeTurnedOff() throws {
        let dir = TestImages.TempDir()
        var c = Config(); c.convertHEIC = false
        let plan = planner(c).plan([TestImages.heic(dir.path("IMG_1.HEIC"))])
        #expect(plan[0].action == .rename)
        #expect(plan[0].target?.hasSuffix(".heic") == true)
    }

    @Test func collisionsWithinABatchAndOnDisk() throws {
        let dir = TestImages.TempDir()
        FileManager.default.createFile(atPath: dir.path("2026-09-21_toronto_img-1.jpg").path, contents: Data())
        let a = TestImages.heic(dir.path("IMG_1.HEIC"))
        let b = TestImages.heic(dir.path("img_1.heif"), seed: 9)
        var p = planner(); p.templateOverride = "{date}_{place}_{orig}"
        #expect(names(p.plan([a, b])) == ["2026-09-21_toronto_img-1-2.jpg", "2026-09-21_toronto_img-1-3.jpg"])
    }

    @Test func skips() throws {
        let dir = TestImages.TempDir()
        let done = TestImages.jpeg(dir.path("2026-09-21_toronto_lamp.jpg"))
        let marked = TestImages.jpeg(dir.path("IMG_9.jpg"))
        try Marker(batch: "b1", sourceSHA1: "x").write(marked)
        let partial = dir.path("IMG_3.HEIC.download")
        FileManager.default.createFile(atPath: partial.path, contents: Data())
        let text = dir.path("notes.txt")
        FileManager.default.createFile(atPath: text.path, contents: Data())
        let plan = planner().plan([done, marked, partial, text, dir.path("missing.heic")])
        #expect(plan.allSatisfy { $0.action == .skip })
        #expect(plan.map(\.reason) == ["already has a date-first name", "already named by betterairdrop", "still downloading", "not a supported image", "no such file"])
    }

    @Test func airdropOnly() throws {
        let dir = TestImages.TempDir()
        let air = TestImages.heic(dir.path("IMG_1.HEIC"))
        try Xattr.set(air, "com.apple.quarantine", Data("0081;6ab3687b;sharingd;24FD9595".utf8))
        let web = TestImages.heic(dir.path("IMG_2.HEIC"), seed: 2)
        try Xattr.set(web, "com.apple.quarantine", Data("0081;6ab3687b;Safari;".utf8))
        var p = planner(); p.airdropOnly = true
        let plan = p.plan([air, web])
        #expect(plan.map(\.action) == [.convert, .skip])
        #expect(plan[0].context?.airdrop == true)
    }

    @Test func placeProviderNone() throws {
        let dir = TestImages.TempDir()
        var c = Config(); c.placeProvider = .none
        let plan = Planner(config: c, places: places).plan([TestImages.heic(dir.path("IMG_1.HEIC"))])
        #expect(names(plan) == ["2026-09-21_img-1.jpg"])
    }

    @Test func unicodeAndSpacesInSourceNames() throws {
        let dir = TestImages.TempDir()
        let url = TestImages.heic(dir.path("Café photo 2 (copy).HEIC"))
        #expect(names(planner().plan([url])) == ["2026-09-21_toronto_cafe-photo-2-copy.jpg"])
    }
}
