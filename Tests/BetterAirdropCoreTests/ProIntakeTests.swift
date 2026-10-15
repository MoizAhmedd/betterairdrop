@testable import BetterAirdropCore
import Foundation
import Testing

/// What the Pro watchers (screenshots, any folder) pick up, and the config keys behind them.
@Suite struct ScreenshotDetectionTests {
    static func markScreenshot(_ url: URL, _ value: Bool = true) {
        let d = try! PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try! Xattr.set(url, ScreenCapture.xattrName, d)
    }

    @Test func readsTheScreenCaptureXattr() {
        let dir = TestImages.TempDir()
        let shot = TestImages.png(dir.path("Screenshot 2026-10-15 at 9.41.03.png"))
        let plain = TestImages.png(dir.path("diagram.png"))
        let no = TestImages.png(dir.path("not.png"))
        Self.markScreenshot(shot)
        Self.markScreenshot(no, false)
        #expect(ScreenCapture.isScreenCapture(shot))
        #expect(!ScreenCapture.isScreenCapture(plain))
        #expect(!ScreenCapture.isScreenCapture(no))
        // Real files carry this exact binary plist (bplist00 + 0x09 = true).
        let real = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30, 0x09, 0x08, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0,
                         0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9])
        #expect(ScreenCapture.decode(real))
        #expect(!ScreenCapture.decode(Data("garbage".utf8)))
    }

    @Test func screenshotFolderFromThePreference() {
        let home = URL(fileURLWithPath: "/Users/test")
        let exists: (URL) -> Bool = { $0.path == "/Users/test/Desktop/images/screenshots" || $0.path == "/Volumes/Shots" }
        func r(_ loc: String?) -> String { ScreenshotFolder.resolve(location: loc, home: home, isDirectory: exists).path }
        #expect(r(nil) == "/Users/test/Desktop")
        #expect(r("") == "/Users/test/Desktop")
        #expect(r("~/Desktop/images/screenshots") == "/Users/test/Desktop/images/screenshots")
        #expect(r("~/Desktop/images/screenshots/") == "/Users/test/Desktop/images/screenshots")
        #expect(r("/Volumes/Shots") == "/Volumes/Shots")
        #expect(r("~/Gone") == "/Users/test/Desktop")          // a deleted folder: macOS falls back to the Desktop
        #expect(r("relative/path") == "/Users/test/Desktop")
    }
}

@Suite struct IntakeFilterTests {
    /// A folder with one of everything: a screenshot, a plain image, an AirDrop, a video, a text file,
    /// a file BetterAirdrop already named and a hidden file.
    func folder() -> Sandbox {
        let s = Sandbox()
        ScreenshotDetectionTests.markScreenshot(TestImages.png(s.file("Screenshot 1.png")))
        TestImages.jpeg(s.file("scan.jpg"))
        AirDropSim.tag(TestImages.heic(s.file("IMG_1.HEIC")))
        try! Data("mov".utf8).write(to: s.file("IMG_1.MOV"))
        try! Data("notes".utf8).write(to: s.file("notes.txt"))
        let named = TestImages.jpeg(s.file("2026-09-21_toronto_lamp.jpg"))
        try! Marker(batch: "b", sourceSHA1: "x").write(named)
        TestImages.jpeg(s.file(".hidden.jpg"))
        return s
    }

    func scan(_ s: Sandbox, _ intake: Watcher.Options.Intake, movies: Bool = true, startedAt: Date = Date().addingTimeInterval(-60)) -> [String] {
        var o = Watcher.Options(folder: s.downloads)
        o.intake = intake
        o.movies = movies
        return Watcher(options: o, planner: s.planner(), committer: s.committer(), startedAt: startedAt)
            .scan().map(\.lastPathComponent).sorted()
    }

    @Test func anyFolderTakesNewImagesOnly() {
        let s = folder()
        #expect(scan(s, .all, movies: false) == ["IMG_1.HEIC", "Screenshot 1.png", "scan.jpg"])
    }

    @Test func anyFolderIgnoresFilesFromBeforeItStarted() {
        let s = folder()
        #expect(scan(s, .all, movies: false, startedAt: Date().addingTimeInterval(60)).isEmpty)
    }

    @Test func screenshotWatcherTakesOnlyScreenshots() {
        let s = folder()
        #expect(scan(s, .screenshots, movies: false) == ["Screenshot 1.png"])
    }

    @Test func airdropIntakeIsUnchanged() {
        let s = folder()
        #expect(scan(s, .airdrop) == ["IMG_1.HEIC"])
        #expect(scan(s, .airdropAndScreenshots) == ["IMG_1.HEIC", "Screenshot 1.png"])
        #expect(scan(s, .all) == ["IMG_1.HEIC", "IMG_1.MOV", "Screenshot 1.png", "scan.jpg"])
    }

    @Test func airdropOnlySwitchMapsToIntake() {
        var o = Watcher.Options(folder: URL(fileURLWithPath: "/tmp"))
        #expect(o.airdropOnly && o.intake == .airdrop)
        o.airdropOnly = false
        #expect(o.intake == .all)
        o.intake = .screenshots
        #expect(!o.airdropOnly)   // so the planner doesn't refuse non-AirDrop screenshots
    }

    @Test func screenshotsAreNamedAsScreenshots() throws {
        let s = Sandbox()
        let shot = TestImages.png(s.file("Screenshot 2026-10-15 at 9.41.03.png"), .init(gps: nil, make: nil, model: nil, userComment: "Screenshot"))
        ScreenshotDetectionTests.markScreenshot(shot)
        var planner = s.planner()
        planner.namer = FakeNamer { ctx in NameSuggestion(kind: ctx.kind, subject: "failed payment notice", confidence: 0.9, backend: "fake") }
        let p = planner.plan([shot])
        #expect(p.first.map { ($0.target! as NSString).lastPathComponent } == "2026-09-21_screenshot_failed-payment-notice.png")
    }
}

/// The Pro watchers run like the AirDrop one, minus the shared lock: settle, name, one batch, undo.
@Suite(.serialized) struct ProWatcherEndToEndTests {
    func service(_ s: Sandbox, _ intake: Watcher.Options.Intake, monitor: ManualFolderMonitor) -> WatchService {
        var planner = s.planner()
        planner.namer = stemNamer
        var o = Watcher.Options(folder: s.downloads)
        o.intake = intake
        o.movies = false
        o.settleInterval = 0.2; o.quietWindow = 0.4; o.pollInterval = 0.05
        return WatchService(watcher: Watcher(options: o, planner: planner, committer: s.committer()), monitor: monitor, lockURL: nil)
    }

    @Test func screenshotWatcherNamesNewScreenshotsAndUndoes() throws {
        let s = Sandbox()
        TestImages.png(s.file("old screenshot.png"))   // there before: left alone
        ScreenshotDetectionTests.markScreenshot(s.file("old screenshot.png"))
        Thread.sleep(forTimeInterval: 2.2)              // older than the watcher's 2 s of slack
        let m = ManualFolderMonitor()
        let svc = service(s, .screenshots, monitor: m)
        let batches = Box<[Watcher.Batch]>([])
        svc.watcher.onBatch = { batches.value.append($0) }
        svc.start()
        #expect(eventually { svc.state == .watching })
        let shot = TestImages.png(s.file("Screenshot 2026-10-15 at 9.41.03.png"), .init(gps: nil, make: nil, model: nil, userComment: "Screenshot"))
        ScreenshotDetectionTests.markScreenshot(shot)
        TestImages.jpeg(s.file("download.jpg"))         // not a screenshot: left alone
        m.fire()
        #expect(eventually { batches.value.count == 1 })
        svc.stop()
        #expect(batches.value[0].photos == 1)
        #expect(s.listing() == ["2026-09-21_screenshot_subject-screenshot-2026-10-15-9.png", "download.jpg", "old screenshot.png"])
        let undone = try s.undoer().undo(.batch(batches.value[0].id))
        #expect(undone.map(\.status) == [.restored])
        #expect(s.listing() == ["Screenshot 2026-10-15 at 9.41.03.png", "download.jpg", "old screenshot.png"])
    }

    @Test func anyFolderWatcherNamesNewImagesOnly() throws {
        let s = Sandbox()
        let m = ManualFolderMonitor()
        let svc = service(s, .all, monitor: m)
        let batches = Box<[Watcher.Batch]>([])
        svc.watcher.onBatch = { batches.value.append($0) }
        svc.start()
        #expect(eventually { svc.state == .watching })
        TestImages.jpeg(s.file("scan_0001.jpg"))
        try Data("mov".utf8).write(to: s.file("scan_0001.mov"))
        try Data("text".utf8).write(to: s.file("readme.txt"))
        m.fire()
        #expect(eventually { batches.value.count == 1 })
        svc.stop()
        #expect(s.listing() == ["2026-09-21_toronto_subject-scan-0001.jpg", "readme.txt", "scan_0001.mov"])
    }
}

/// Undo while a watcher runs: the restored original arrived after the watcher started (quarantine
/// time, or the undo's own inode change), so without the undone mark it would be renamed straight back.
@Suite struct UndoIsNotRenamedBackTests {
    @Test(arguments: [Watcher.Options.Intake.airdrop, .screenshots, .all])
    func undoneFileStaysUndone(_ intake: Watcher.Options.Intake) throws {
        let s = Sandbox()
        var o = Watcher.Options(folder: s.downloads)
        o.intake = intake
        o.settleInterval = 0.1; o.quietWindow = 0.2; o.pollInterval = 0.05
        o.isScreenshot = { _ in true }
        var planner = s.planner()
        planner.namer = stemNamer
        let w = Watcher(options: o, planner: planner, committer: s.committer(), startedAt: Date().addingTimeInterval(-5))
        AirDropSim.tag(TestImages.png(s.file("Shot.png")))
        let b = try #require(w.runOnce())
        _ = try s.undoer().undo(.batch(b.id))
        #expect(w.runOnce() == nil)
        #expect(s.listing() == ["Shot.png"])
        #expect(planner.skipReason(s.file("Shot.png")) == nil)   // renaming it by hand still works
    }
}

@Suite struct DateFormatTests {
    @Test func formats() {
        #expect(DateFormat.iso.apply("2026-09-24") == "2026-09-24")
        #expect(DateFormat.compact.apply("2026-09-24") == "20260924")
        #expect(DateFormat.month.apply("2026-09-24") == "2026-09")
        #expect(DateFormat.dayFirst.apply("2026-09-24") == "24-09-2026")
        #expect(DateFormat.monthFirst.apply("2026-09-24") == "09-24-2026")
        #expect(DateFormat.compact.apply("") == "")
        #expect(DateFormat.compact.apply("garbage") == "garbage")
    }

    @Test func plannerUsesTheConfiguredFormat() throws {
        var c = Config()
        c.dateFormat = .compact
        let p = Planner(config: c, places: nil)
        let ctx = PhotoContext(file: "/x/IMG_1.HEIC", metadata: { var m = PhotoMetadata(); m.date = "2026-09-21"; return m }())
        let s = NameSuggestion(kind: .photo, subject: "walnut lamp", confidence: 0.9, backend: "fake")
        #expect(try p.compose(url: URL(fileURLWithPath: "/x/IMG_1.HEIC"), context: ctx, suggestion: s).0 == "20260921_walnut-lamp")
    }
}

@Suite struct ProConfigTests {
    @Test func parsesAndWritesTheProKeys() throws {
        let c = try Config.parse("""
        date_format = "yyyymmdd"
        [watch]
        screenshots = true
        extra_folders = ["~/Pictures/Inbox", "/Volumes/Card/DCIM, 2026" ,]   # a comma inside a string
        """)
        #expect(c.dateFormat == .compact)
        #expect(c.watchScreenshots)
        #expect(c.watchExtraFolders == ["~/Pictures/Inbox", "/Volumes/Card/DCIM, 2026"])
        let round = try Config.parse(c.rendered(updating: nil))
        #expect(round == c)
    }

    @Test func emptyArrayAndDefaultsAreNotWritten() throws {
        #expect(try Config.parse("[watch]\nextra_folders = []").watchExtraFolders == [])
        let text = Config().rendered(updating: nil)
        #expect(!text.contains("extra_folders") && !text.contains("date_format") && !text.contains("screenshots"))
    }

    @Test func rejectsBadValues() {
        #expect(throws: Config.ParseError.self) { try Config.parse("date_format = \"dd/mm\"") }
        #expect(throws: Config.ParseError.self) { try Config.parse("[watch]\nextra_folders = \"~/x\"") }
        #expect(throws: Config.ParseError.self) { try Config.parse("[watch]\nextra_folders = [~/x]") }
        #expect(throws: Config.ParseError.self) { try Config.parse("[watch]\nextra_folders = [\"a\" \"b\"]") }
    }

    @Test func editingKeepsTheArrayLine() throws {
        var c = try Config.parse("[watch]\nextra_folders = [\"~/a\"]  # mine\n")
        c.watchExtraFolders.append("~/b")
        #expect(c.rendered(updating: "[watch]\nextra_folders = [\"~/a\"]  # mine\n") == "[watch]\nextra_folders = [\"~/a\", \"~/b\"]  # mine\n")
    }
}
