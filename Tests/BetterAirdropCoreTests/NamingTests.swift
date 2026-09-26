@testable import BetterAirdropCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

typealias Line = VisionResult.TextLine
typealias Label = VisionResult.Label

func receiptVision() -> VisionResult {
    VisionResult(labels: [Label("document", 0.8), Label("receipt", 0.6)], lines: [
        Line("LOBLAWS", confidence: 0.95, height: 0.05, top: 0.05),
        Line("Store 1234 Queen St W", confidence: 0.9, height: 0.02, top: 0.12),
        Line("BANANAS 2.49", confidence: 0.9, height: 0.02, top: 0.3),
        Line("OAT MILK 5.99", confidence: 0.9, height: 0.02, top: 0.33),
        Line("SUBTOTAL 74.44", confidence: 0.9, height: 0.02, top: 0.6),
        Line("HST 9.68", confidence: 0.9, height: 0.02, top: 0.63),
        Line("TOTAL", confidence: 0.9, height: 0.025, top: 0.66),
        Line("$84.12", confidence: 0.9, height: 0.025, top: 0.66),
        Line("VISA 84.12", confidence: 0.9, height: 0.02, top: 0.7),
    ])
}

@Suite struct KindClassifierTests {
    let meta = PhotoMetadata()

    @Test func screenshotWinsFromMetadata() {
        var m = meta; m.userComment = "Screenshot"
        #expect(KindClassifier.classify(metadata: m, vision: receiptVision()).0 == .screenshot)
        var m2 = meta; m2.creatorBundleID = "com.apple.springboard"
        #expect(KindClassifier.classify(metadata: m2, vision: nil).0 == .screenshot)
    }

    @Test func receipt() {
        let (k, why) = KindClassifier.classify(metadata: meta, vision: receiptVision())
        #expect(k == .receipt)
        #expect(why.contains("amounts"))
    }

    @Test func whiteboard() {
        let v = VisionResult(labels: [Label("structure", 0.9), Label("whiteboard", 0.7)], lines: [Line("Q3 roadmap")])
        #expect(KindClassifier.classify(metadata: meta, vision: v).0 == .whiteboard)
    }

    @Test func document() {
        let lines = (1...12).map { Line("Paragraph line number \($0) of the letter") }
        #expect(KindClassifier.classify(metadata: meta, vision: VisionResult(lines: lines, documentConfidence: 0.95, documentArea: 0.6)).0 == .document)
        #expect(KindClassifier.classify(metadata: meta, vision: VisionResult(labels: [Label("document", 0.9)], lines: lines)).0 == .document)
    }

    /// M0: document segmentation fires on ordinary objects (0.99). Without text it's a photo.
    @Test func documentOutlineAloneIsAPhoto() {
        let v = VisionResult(labels: [Label("baked_goods", 0.6)], lines: [], documentConfidence: 0.99, documentArea: 0.35)
        #expect(KindClassifier.classify(metadata: meta, vision: v).0 == .photo)
    }

    @Test func pricesOnAMenuBoardWithoutReceiptWordsAreNotAReceipt() {
        let v = VisionResult(lines: [Line("Espresso 3.50"), Line("Latte 4.75"), Line("Mocha 5.25"), Line("Open daily")])
        #expect(KindClassifier.classify(metadata: meta, vision: v).0 == .photo)
    }
}

@Suite struct VisionNamerTests {
    func suggest(_ v: VisionResult, kind: Kind = .photo) throws -> NameSuggestion {
        try VisionNamer().suggest(for: URL(fileURLWithPath: "/x/IMG_1.HEIC"),
                                  context: PhotoContext(file: "/x/IMG_1.HEIC", metadata: PhotoMetadata(), vision: v, kind: kind))
    }

    @Test func dropsParentLabelsAndKeepsTwoLeaves() throws {
        let v = VisionResult(labels: [Label("tableware", 0.95), Label("utensil", 0.95), Label("drinking_glass", 0.95),
                                      Label("structure", 0.82), Label("table", 0.4), Label("candle", 0.35)])
        let s = try suggest(v)
        #expect(s.subject == "drinking glass table")
        #expect(s.confidence == 0.95)
    }

    @Test func screenshotUsesProminentTextNotTheStatusBar() throws {
        let v = VisionResult(lines: [
            Line("9:41", confidence: 1, height: 0.02, top: 0.01),
            Line("Payments", confidence: 0.9, height: 0.02, top: 0.08),
            Line("Failed payment", confidence: 0.95, height: 0.045, top: 0.2),
            Line("Your card was declined by the issuer", confidence: 0.9, height: 0.018, top: 0.3),
        ])
        #expect(try suggest(v, kind: .screenshot).subject == "Failed payment")
    }

    @Test func receiptMerchantAndTotal() throws {
        let s = try suggest(receiptVision(), kind: .receipt)
        #expect(s.merchant == "LOBLAWS")
        #expect(s.total == "84-12")
    }

    @Test func photoWithWeakLabelsFallsBackToConfidentText() throws {
        let v = VisionResult(labels: [Label("book", 0.24)], lines: [
            Line("CITY MARKET", confidence: 0.95, height: 0.08), Line("open daily", confidence: 0.9, height: 0.03),
            Line("rnarketplace", confidence: 0.5, height: 0.1),   // big but unsure: an OCR misread
        ])
        #expect(try suggest(v).subject == "CITY MARKET")
    }

    @Test func nothingUsableMeansZeroConfidence() throws {
        let s = try suggest(VisionResult(labels: [Label("structure", 0.9), Label("statue", 0.21)]))
        #expect(s.subject == "" && s.confidence == 0)
    }
}

/// A namer that returns a fixed suggestion, for pipeline tests.
struct FakeNamer: Namer {
    var id = "fake"
    var make: @Sendable (PhotoContext) -> NameSuggestion
    func availability() -> Availability { .ready }
    func suggest(for url: URL, context: PhotoContext) throws -> NameSuggestion { make(context) }
}

@Suite struct NamingPipelineTests {
    let places = try! Places(packed: Places.pack(geonamesTSV: TestImages.geonamesSample))

    func plan(_ url: URL, vision: VisionResult?, namer: any Namer = VisionNamer()) -> Proposal {
        var p = Planner(config: Config(), places: places, namer: namer)
        p.analyzer = { _ in vision }
        return p.plan([url])[0]
    }

    @Test func perKindTemplates() throws {
        let dir = TestImages.TempDir()
        let receipt = plan(TestImages.heic(dir.path("IMG_0009.HEIC")), vision: receiptVision())
        #expect((receipt.target! as NSString).lastPathComponent == "2026-09-21_receipt_loblaws_84-12.jpg")

        let shot = plan(TestImages.png(dir.path("IMG_0008.PNG"), .init(gps: nil, userComment: "Screenshot")),
                        vision: VisionResult(lines: [Line("Stripe", height: 0.02, top: 0.1), Line("Failed payment", confidence: 0.95, height: 0.05, top: 0.2)]))
        #expect((shot.target! as NSString).lastPathComponent == "2026-09-21_screenshot_failed-payment.png")

        let doc = plan(TestImages.heic(dir.path("IMG_0010.HEIC"), seed: 3),
                       vision: VisionResult(lines: [Line("Lease Agreement", height: 0.06)] + (1...10).map { Line("clause \($0) text here", height: 0.015) },
                                            documentConfidence: 0.95, documentArea: 0.7))
        #expect((doc.target! as NSString).lastPathComponent == "2026-09-21_doc_lease-agreement.jpg")

        let wb = plan(TestImages.heic(dir.path("IMG_0011.HEIC"), seed: 4),
                      vision: VisionResult(labels: [Label("whiteboard", 0.8)], lines: [Line("Sprint 42 retro", height: 0.08)]))
        #expect((wb.target! as NSString).lastPathComponent == "2026-09-21_whiteboard_sprint-42-retro.jpg")
    }

    @Test func photoGetsLabelsAndPlace() {
        let dir = TestImages.TempDir()
        let p = plan(TestImages.heic(dir.path("IMG_0001.HEIC")), vision: VisionResult(labels: [Label("portal", 0.85), Label("window", 0.85), Label("brick", 0.4)]))
        #expect((p.target! as NSString).lastPathComponent == "2026-09-21_toronto_window-brick.jpg")
        #expect(p.suggestion?.backend == "vision")
    }

    @Test func lowConfidenceFallsBackToTheOriginalNumber() {
        let dir = TestImages.TempDir()
        let p = plan(TestImages.heic(dir.path("IMG_5266.HEIC")), vision: VisionResult(labels: [Label("structure", 0.7)]))
        #expect((p.target! as NSString).lastPathComponent == "2026-09-21_toronto_img-5266.jpg")
        let weak = plan(TestImages.heic(dir.path("IMG_5267.HEIC")), vision: nil,
                        namer: FakeNamer { _ in NameSuggestion(kind: .photo, subject: "maybe a cat", confidence: 0.1, backend: "fake") })
        #expect((weak.target! as NSString).lastPathComponent == "2026-09-21_toronto_img-5267.jpg")
    }

    @Test func receiptWithoutMerchantOrTotalStillSaysReceipt() {
        let dir = TestImages.TempDir()
        let p = plan(TestImages.heic(dir.path("IMG_1.HEIC")), vision: nil, namer: FakeNamer { _ in
            NameSuggestion(kind: .receipt, subject: "", confidence: 0.2, backend: "fake")
        })
        #expect((p.target! as NSString).lastPathComponent == "2026-09-21_receipt_img-1.jpg")
    }

    @Test func backends() throws {
        #expect(try Backends.resolve("auto", auth: .none).id == "vision")          // no macOS 27, no credential
        #expect(throws: BackendError.self) { try Backends.resolve("apple", auth: .none) }
        #expect(throws: BackendError.self) { try Backends.resolve("claude", auth: .none) }
        #expect(throws: BackendError.unknown("gpt")) { try Backends.resolve("gpt", auth: .none) }
        if case .unavailable(let why) = AppleFMNamer().availability() { #expect(why.contains("macOS 27")) }
    }
}

/// Real Vision on synthetic rendered images (no personal photos). Skipped on CI: GitHub's macOS
/// runners are VMs without a GPU or Neural Engine, and Vision requests hang there.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "Vision hangs on GitHub's GPU-less macOS runners"))
struct VisionIntegrationTests {
    /// Renders lines of black text on a white "page" inside a grey frame.
    static func render(_ lines: [(String, CGFloat)], width: Int = 900, height: Int = 1400, page: CGRect? = nil, to url: URL,
                       type: UTType = .jpeg, meta: TestImages.Meta = .init()) -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.35, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let pageRect = page ?? CGRect(x: 60, y: 60, width: width - 120, height: height - 120)
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(pageRect)
        var y = pageRect.maxY - 40
        for (text, size) in lines {
            y -= size * 1.5
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attr = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font,
                                                                     .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: pageRect.minX + 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, TestImages.properties(meta) as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    @Test func receiptImage() throws {
        let dir = TestImages.TempDir()
        let url = Self.render([("LOBLAWS", 64), ("Queen St W Toronto", 26), ("BANANAS        2.49", 30), ("OAT MILK       5.99", 30),
                               ("COFFEE BEANS  65.96", 30), ("SUBTOTAL      74.44", 30), ("HST            9.68", 30),
                               ("TOTAL         84.12", 40), ("VISA          84.12", 30)],
                              width: 700, page: CGRect(x: 100, y: 60, width: 500, height: 1280), to: dir.path("IMG_0009.JPG"))
        var planner = Planner(config: Config(), places: try! Places(packed: Places.pack(geonamesTSV: TestImages.geonamesSample)), namer: VisionNamer())
        planner.analyzer = { VisionAnalyzer.analyze($0) }
        let p = planner.plan([url])[0]
        #expect(p.context?.kind == .receipt, "\(p.context?.kindReason ?? "")")
        #expect((p.target! as NSString).lastPathComponent == "2026-09-21_receipt_loblaws_84-12.jpg")
    }

    @Test func documentImage() throws {
        let dir = TestImages.TempDir()
        let body = (1...12).map { ("This agreement is made between the parties, clause \($0).", CGFloat(24)) }
        let url = Self.render([("Lease Agreement", 56)] + body, to: dir.path("IMG_0010.JPG"))
        let v = try #require(VisionAnalyzer.analyze(url))
        #expect(v.lines.count >= 10)
        let (kind, why) = KindClassifier.classify(metadata: PhotoMetadata(), vision: v)
        #expect(kind == .document, "\(why); labels \(v.labels.prefix(4)); doc \(String(describing: v.documentConfidence)) \(String(describing: v.documentArea))")
        let s = try VisionNamer().suggest(for: url, context: PhotoContext(file: url.path, metadata: PhotoMetadata(), vision: v, kind: kind))
        #expect(s.subject == "Lease Agreement")
    }

    @Test func screenshotImage() throws {
        let dir = TestImages.TempDir()
        let url = Self.render([("9:41", 22), ("Payments", 28), ("Failed payment", 60), ("Your card was declined.", 26)],
                              width: 600, height: 1300, page: CGRect(x: 0, y: 0, width: 600, height: 1300),
                              to: dir.path("IMG_0008.PNG"), type: .png, meta: .init(gps: nil, userComment: "Screenshot"))
        var planner = Planner(config: Config(), places: nil, namer: VisionNamer())
        planner.analyzer = { VisionAnalyzer.analyze($0) }
        let p = planner.plan([url])[0]
        #expect(p.action == .rename)
        #expect((p.target! as NSString).lastPathComponent == "2026-09-21_screenshot_failed-payment.png")
    }
}

/// Vision runs only when its output is used (docs/perf.md).
@Suite struct VisionSkipTests {
    struct Failing: Namer {
        var id = "claude"
        func availability() -> Availability { .ready }
        func suggest(for url: URL, context: PhotoContext) throws -> NameSuggestion { throw ClaudeNamer.Error.network("offline") }
    }

    final class Calls: @unchecked Sendable { var n = 0 }

    func planner(_ namer: any Namer, _ calls: Calls) -> Planner {
        var p = Planner(config: Config(), places: nil, namer: namer)
        p.analyzer = { _ in calls.n += 1; return VisionResult(labels: [.init("lamp", 0.8)]) }
        return p
    }

    let claude = FakeNamer(id: "claude") { NameSuggestion(kind: $0.kind, subject: "walnut lamp", confidence: 0.9, backend: "claude") }

    @Test func cameraPhotosNamedByClaudeSkipVision() throws {
        let dir = TestImages.TempDir()
        let calls = Calls()
        let p = planner(claude, calls).plan([TestImages.heic(dir.path("IMG_1.HEIC"))])[0]
        #expect(calls.n == 0)
        #expect(p.context?.vision == nil && p.timings?[.vision] == nil)
        #expect((p.target! as NSString).lastPathComponent == "2026-09-21_walnut-lamp.jpg")
    }

    @Test func screenshotsAndUnknownImagesStillGetVision() throws {
        let dir = TestImages.TempDir()
        let calls = Calls()
        _ = planner(claude, calls).plan([TestImages.png(dir.path("IMG_2.PNG"), .init(gps: nil, userComment: "Screenshot"))])
        #expect(calls.n == 1, "screenshot: OCR goes to Claude")
        _ = planner(claude, calls).plan([TestImages.png(dir.path("saved.png"), .init(gps: nil, make: nil, model: nil))])
        #expect(calls.n == 2, "no camera metadata")
    }

    @Test func visionNamerAlwaysGetsVision() throws {
        let dir = TestImages.TempDir()
        let calls = Calls()
        let p = planner(VisionNamer(), calls).plan([TestImages.heic(dir.path("IMG_3.HEIC"))])[0]
        #expect(calls.n == 1 && p.suggestion?.subject == "lamp")
    }

    @Test func claudeFailingOnASkippedPhotoFallsBackWithVision() throws {
        let dir = TestImages.TempDir()
        let calls = Calls()
        let p = planner(FallbackNamer(primary: Failing(), fallback: VisionNamer()), calls).plan([TestImages.heic(dir.path("IMG_4.HEIC"))])[0]
        #expect(calls.n == 1)
        #expect(p.suggestion?.backend == "vision" && p.suggestion?.subject == "lamp")
        #expect(p.suggestion?.fallbackFrom?.hasPrefix("claude: network error") == true)
        #expect((p.target! as NSString).lastPathComponent == "2026-09-21_lamp.jpg")
    }
}
