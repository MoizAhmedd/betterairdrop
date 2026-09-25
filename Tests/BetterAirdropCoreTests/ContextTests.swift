@testable import BetterAirdropCore
import Foundation
import Testing

@Suite struct ConfigTests {
    @Test func defaultsWhenEmpty() throws {
        #expect(try Config.parse("") == Config())
        #expect(try Config.load(from: URL(fileURLWithPath: "/nonexistent/betterairdrop.toml")) == Config())
    }

    @Test func parsesThePlanExample() throws {
        let c = try Config.parse("""
        # betterairdrop config
        backend = "vision"          # comment after a value
        template = "{date}_{subject}"
        originals = "keep"
        convert_heic = false
        jpeg_quality = 0.9
        max_subject_words = 4

        [watch]
        airdrop_only = false
        folder = "~/Desktop # not a comment"

        [place]
        provider = "none"
        strip_gps_from_output = true

        [templates]
        receipt = "{date}_r_{merchant}"

        [claude]
        model = "claude-haiku-4-5-20251001"
        """)
        #expect(c.backend == "vision")
        #expect(c.template == "{date}_{subject}")
        #expect(c.originals == .keep)
        #expect(c.convertHEIC == false)
        #expect(c.jpegQuality == 0.9)
        #expect(c.maxSubjectWords == 4)
        #expect(c.watchAirdropOnly == false)
        #expect(c.watchFolder == "~/Desktop # not a comment")
        #expect(c.placeProvider == PlaceProvider.none)
        #expect(c.stripGPSFromOutput)
        #expect(c.kindTemplates["receipt"] == "{date}_r_{merchant}")
        #expect(c.kindTemplates["screenshot"] == "{date}_screenshot_{subject}")
        #expect(c.unknownKeys.isEmpty)
    }

    typealias PlaceProvider = Config.PlaceProvider

    @Test func errorsNameTheLine() {
        #expect(throws: Config.ParseError.self) { try Config.parse("backend = vision") }       // unquoted
        #expect { try Config.parse("\n\noriginals = \"shred\"") } throws: { ($0 as? Config.ParseError)?.line == 3 }
        #expect { try Config.parse("template = \"{date}_{nope}\"") } throws: { "\($0)".contains("unknown template token") }
        #expect(throws: Config.ParseError.self) { try Config.parse("[watch\nenabled = true") }
        #expect(throws: Config.ParseError.self) { try Config.parse("jpeg_quality = 7") }
    }

    @Test func unknownKeysAreCollectedNotFatal() throws {
        #expect(try Config.parse("colour = \"red\"\n[watch]\nspeed = 3").unknownKeys == ["colour", "watch.speed"])
    }

    @Test func setUsesTheSameValidation() throws {
        var c = Config()
        try c.set("watch.enabled", "false")
        try c.set("backend", "claude")
        #expect(c.watchEnabled == false && c.backend == "claude")
        #expect(throws: Config.ParseError.self) { try c.set("backend", "gpt") }
    }
}

@Suite struct MetadataTests {
    @Test func readsFabricatedExifAndGPS() throws {
        let dir = TestImages.TempDir()
        let url = TestImages.heic(dir.path("IMG_0001.HEIC"), .init(dateTimeOriginal: "2026:09:21 14:03:10", offset: "-04:00",
                                                                    gps: (43.6532, -79.3832), orientation: 6))
        let m = try PhotoMetadata.read(url)
        #expect(m.date == "2026-09-21")
        #expect(m.time == "1403")
        #expect(m.offset == "-04:00")
        #expect(m.dateSource == "exif")
        #expect(abs((m.latitude ?? 0) - 43.6532) < 1e-4)
        #expect(abs((m.longitude ?? 0) - -79.3832) < 1e-4)   // W → negative
        #expect(m.model == "iPhone 15 Pro")
        #expect(m.deviceSlug == "iphone-15-pro")
        #expect(m.orientation == 6)
        #expect(m.uti == "public.heic")
    }

    @Test func southernAndEasternHemispheres() throws {
        let dir = TestImages.TempDir()
        let url = TestImages.jpeg(dir.path("a.jpg"), .init(gps: (-33.8688, 151.2093)))
        let m = try PhotoMetadata.read(url)
        #expect((m.latitude ?? 0) < 0 && (m.longitude ?? 0) > 0)
    }

    @Test func fallsBackToFileDateWithoutExif() throws {
        let dir = TestImages.TempDir()
        let url = TestImages.jpeg(dir.path("a.jpg"), .init(dateTimeOriginal: nil, offset: nil, gps: nil))
        let m = try PhotoMetadata.read(url)
        #expect(m.dateSource == "file")
        #expect(m.date?.count == 10)
        #expect(!m.hasGPS)
    }

    @Test func screenshotSignal() throws {
        let dir = TestImages.TempDir()
        let url = TestImages.png(dir.path("IMG_0002.PNG"), .init(gps: nil, userComment: "Screenshot"))
        #expect(try PhotoMetadata.read(url).isScreenshotByMetadata)
        let url2 = TestImages.png(dir.path("b.png"), .init(gps: nil))
        try Xattr.set(url2, "com.apple.assetsd.creatorBundleID", Data("com.apple.springboard".utf8))
        #expect(try PhotoMetadata.read(url2).isScreenshotByMetadata)
    }

    @Test func rejectsNonImages() {
        let dir = TestImages.TempDir()
        let url = dir.path("notes.jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data("hello".utf8))
        #expect(throws: PhotoMetadata.Error.self) { try PhotoMetadata.read(url) }
    }

    @Test func exifDateParsing() {
        #expect(PhotoMetadata.parseExifDate("2026:01:02 03:04:05")! == ("2026-01-02", "0304"))
        #expect(PhotoMetadata.parseExifDate("0000:00:00 00:00:00") == nil)
        #expect(PhotoMetadata.parseExifDate("garbage") == nil)
    }
}

@Suite struct PlacesTests {
    let places = try! Places(packed: Places.pack(geonamesTSV: TestImages.geonamesSample))

    @Test func roundTripsThePackedFormat() {
        #expect(places.count == 5)   // the PPLX district is dropped
    }

    @Test func nearestCity() {
        #expect(places.nearest(latitude: 43.6532, longitude: -79.3832)?.city == "Toronto")
        #expect(places.nearest(latitude: 45.5017, longitude: -73.5673)?.city == "Montreal")   // ASCII name
        #expect(places.nearest(latitude: 43.59, longitude: -79.64)?.city == "Mississauga")
        #expect(places.nearest(latitude: 38.7223, longitude: -9.1393)?.countryCode == "PT")
    }

    @Test func cityNotDistrict() {
        // Central Copenhagen is closer to the "Indre By" district point, but districts aren't packed.
        #expect(places.nearest(latitude: 55.6805, longitude: 12.5790)?.city == "Copenhagen")
    }

    @Test func nothingInTheMiddleOfLakeOntario() {
        #expect(places.nearest(latitude: 43.62, longitude: -77.8) == nil)
    }

    @Test func bundledTableLoads() throws {
        let p = try #require(Places.shared)
        #expect(p.count > 20_000)
        #expect(p.nearest(latitude: 43.6532, longitude: -79.3832)?.city == "Toronto")
        #expect(p.nearest(latitude: 45.5017, longitude: -73.5673)?.city == "Montreal")
        #expect(p.nearest(latitude: 43.5890, longitude: -79.6441)?.city == "Mississauga")
        #expect(p.nearest(latitude: 40.7580, longitude: -73.9855)?.city == "New York City")
        #expect(p.nearest(latitude: 38.7223, longitude: -9.1393)?.city == "Lisbon")
        #expect(p.nearest(latitude: 55.6761, longitude: 12.5683)?.city == "Copenhagen")
    }

    @Test func rejectsGarbage() {
        #expect(throws: Places.Error.self) { try Places(packed: Data("nope".utf8)) }
    }
}

@Suite struct QuarantineTests {
    @Test func parsesAirDrop() throws {
        let q = try #require(Quarantine("0081;6ab3687b;sharingd;24FD9595-6AF5-4D12-AB50-8B4EB3393CE5"))
        #expect(q.isAirDrop)
        #expect(q.flags == "0081")
        #expect(q.timestamp == Date(timeIntervalSince1970: 0x6ab3687b))
    }

    @Test func otherAgents() throws {
        #expect(try #require(Quarantine("0083;69790e6c;Arc;")).isAirDrop == false)
        // A plain `cp` of an AirDropped file gets a fresh entry with an empty agent (observed in M0).
        #expect(try #require(Quarantine("0281;6ab583f5;;FF4E730C")).isAirDrop == false)
        #expect(Quarantine("") == nil)
    }
}

@Suite struct LegacyMigrationTests {
    @Test func movesOldFolderOnceAndNeverOverwrites() throws {
        let t = TestImages.TempDir()
        let old = t.path("airname"), new = t.path("sub/betterairdrop")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"backend = "vision""#.utf8).write(to: old.appendingPathComponent("config.toml"))
        #expect(LegacyMigration.move(old, to: new))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("config.toml").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        // A second old folder appearing later never replaces the new one.
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        #expect(!LegacyMigration.move(old, to: new))
    }

    @Test func legacyMarkerIsStillHonoured() throws {
        let t = TestImages.TempDir()
        let f = TestImages.jpeg(t.path("a.jpg"))
        try Xattr.set(f, Marker.legacyName, Data(#"{"batch":"b","sourceSHA1":"x","v":1}"#.utf8))
        #expect(Marker.read(f)?.batch == "b")
        Marker.remove(f)
        #expect(Marker.read(f) == nil)
    }
}

@Suite struct ConfigWriterTests {
    let original = """
    # My airdrop naming setup
    backend = "auto"   # try claude first

    [watch]
    folder = "~/Downloads"   # where AirDrop lands
    # notify = false
    unknown_thing = 3

    [claude]
    model = "claude-haiku-4-5"
    """

    @Test func editsInPlaceAndKeepsComments() throws {
        var c = try Config.parse(original)
        c.backend = "vision"
        c.watchFolder = #"~/Desktop/in "box""#
        c.claudeInAuto = false
        c.convertHEIC = false
        let text = c.rendered(updating: original)
        #expect(text.contains("# My airdrop naming setup"))
        #expect(text.contains(#"backend = "vision"   # try claude first"#))
        #expect(text.contains(#"folder = "~/Desktop/in \"box\""   # where AirDrop lands"#))
        #expect(text.contains("# notify = false"))
        #expect(text.contains("unknown_thing = 3"), "unknown keys are left alone")
        // New keys go under the right table; top-level keys go before the first table.
        let lines = text.components(separatedBy: "\n")
        let claudeHeader = try #require(lines.firstIndex(of: "[claude]"))
        #expect(lines[(claudeHeader + 1)...].contains("auto = false"))
        let heic = try #require(lines.firstIndex(of: "convert_heic = false"))
        #expect(heic < lines.firstIndex(of: "[watch]")!)
        #expect(try Config.parse(text) == { var d = c; d.unknownKeys = ["watch.unknown_thing"]; return d }())
    }

    @Test func everyControlRoundTrips() throws {
        var c = Config()
        c.backend = "claude"; c.template = "{date}_{subject}"; c.originals = .keep; c.convertHEIC = false
        c.jpegQuality = 0.75; c.maxSubjectWords = 4; c.watchFolder = "/tmp/x"; c.watchAirdropOnly = false
        c.watchNotify = false; c.placeProvider = .none; c.stripGPSFromOutput = true
        c.claudeModel = "claude-sonnet-4-5"; c.claudeInAuto = false
        c.kindTemplates["receipt"] = "{date}_receipt_{total}"
        let t = TestImages.TempDir()
        let url = t.path("sub/config.toml")
        try c.save(to: url)
        #expect(try Config.load(from: url) == c)
        // Saving the defaults over an empty file writes nothing but a newline.
        #expect(Config().rendered(updating: nil) == "\n")
        // Saving again changes nothing.
        let once = try String(contentsOf: url, encoding: .utf8)
        try Config.load(from: url).save(to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == once)
    }
}
