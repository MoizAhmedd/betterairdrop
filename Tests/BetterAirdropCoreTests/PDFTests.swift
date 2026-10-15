@testable import BetterAirdropCore
import Foundation
import Testing

/// A document namer that answers like a model would, from the PDF's text, and records what it was sent.
struct FakeDocNamer: Namer {
    var id = "fake"
    var answer: @Sendable (DocumentText) -> DocumentPrompt.Answer?
    func availability() -> Availability { .ready }
    func suggest(for url: URL, context: PhotoContext) throws -> NameSuggestion {
        guard let doc = context.document, let a = answer(doc) else { throw ClaudeNamer.Error.badOutput("no answer") }
        return a.suggestion(backend: id, maxWords: 6, source: "fake")
    }
}

let invoiceAnswer = DocumentPrompt.Answer(subject: "Internet and TV bill", kind: "invoice", issuer: "Bell Canada",
                                          amount: "84.12", date: "2026-10-12", confidence: 0.9)
let leaseAnswer = DocumentPrompt.Answer(subject: "lease agreement 45 carlton st", kind: "contract", issuer: "",
                                        amount: "", date: "2026-09-30", confidence: 0.9)

/// Answers from what the text says, so a test can see the namer got the text.
let docNamer = FakeDocNamer { doc in
    if doc.text.contains("Bell Canada") { return invoiceAnswer }
    if doc.text.uppercased().contains("LEASE") { return leaseAnswer }
    return nil
}

func pdfPlanner(_ s: Sandbox, namer: (any Namer)? = docNamer) -> Planner {
    var p = s.planner()
    p.pdfs = true
    p.documentNamer = namer
    return p
}

func name(_ p: Proposal) -> String? { p.target.map { ($0 as NSString).lastPathComponent } }

@Suite struct PDFTextTests {
    let dir = TestImages.TempDir()

    @Test func readsTheTextLayerAndTitle() throws {
        let url = TestPDFs.text(dir.path("document (3).pdf"), TestPDFs.invoiceLines, title: "Invoice 83721")
        var ocrRan = false
        let d = try PDFText.extract(url) { _ in ocrRan = true; return nil }
        #expect(d.source == .text && !ocrRan)
        #expect(d.text.hasPrefix("INVOICE\nBell Canada\nInvoice date: October 12, 2026"))
        #expect(d.title == "Invoice 83721")
        #expect(d.pages == 1)
        #expect(d.created?.count == 10)
    }

    @Test func aScanGoesToOCR() throws {
        let url = TestPDFs.scanned(dir.path("scan0004.pdf"), TestPDFs.leaseLines)
        let d = try PDFText.extract(url)   // real Vision OCR, on this Mac
        #expect(d.source == .ocr)
        #expect(d.text.uppercased().contains("LEASE AGREEMENT"))
        #expect(d.text.contains("Carlton"))
    }

    @Test func onlyTheFirstTwoPagesAndAtMost4000Characters() throws {
        let filler = Array(repeating: String(repeating: "lorem ipsum dolor ", count: 4), count: 30)
        let url = TestPDFs.text(dir.path("long.pdf"), pages: [["PAGE ONE"] + filler, ["PAGE TWO"] + filler, ["PAGE THREE"]])
        let d = try PDFText.extract(url)
        #expect(d.pages == 3)
        #expect(d.text.utf16.count <= PDFText.maxChars)
        #expect(d.text.contains("PAGE ONE") && !d.text.contains("PAGE THREE"))
        #expect(PDFText.cut("😀😀😀", max: 5) == "😀😀")   // never splits a character
    }

    @Test func junkTitlesAreDropped() {
        #expect(PDFText.cleanTitle("Microsoft Word - Document1") == nil)
        #expect(PDFText.cleanTitle("untitled") == nil)
        #expect(PDFText.cleanTitle("scan0004.pdf") == nil)
        #expect(PDFText.cleanTitle(" Attention Is All You Need ") == "Attention Is All You Need")
    }

    @Test func encryptedPDFsAreNotRead() {
        let owner = TestPDFs.encrypted(dir.path("statement.pdf"))
        let locked = TestPDFs.encrypted(dir.path("locked.pdf"), userPassword: "secret")
        #expect(PDFIntake.isEncrypted(owner) && PDFIntake.isEncrypted(locked))
        #expect(throws: PDFText.Error.encrypted) { try PDFText.extract(owner) }
        #expect(!PDFIntake.isEncrypted(TestPDFs.text(dir.path("plain.pdf"), ["hello there"])))
    }
}

@Suite struct DocumentPromptTests {
    @Test func parsesTheSixFields() throws {
        let a = try DocumentPrompt.parse(#"Here: {"subject":"Internet and TV bill","kind":"invoice","issuer":"Bell Canada","amount":"84.12","date":"2026-10-12","confidence":0.9}"#)
        #expect(a == invoiceAnswer)
        #expect(throws: ClaudeNamer.Error.self) { try DocumentPrompt.parse(#"{"subject":"a lamp","kind":"photo","confidence":1}"#) }
        #expect(throws: ClaudeNamer.Error.self) { try DocumentPrompt.parse(#"{"subject":"","kind":"invoice","confidence":1}"#) }
        #expect(throws: ClaudeNamer.Error.self) { try DocumentPrompt.parse("no json") }
    }

    @Test func everyKindIsKnown() {
        #expect(DocumentPrompt.kinds == ["invoice", "receipt", "statement", "contract", "form", "letter", "ticket", "manual", "paper", "other"])
        for k in DocumentPrompt.kinds { #expect(Kind(rawValue: k) != nil) }
    }

    @Test func fieldsGoWhereTheKindUsesThem() {
        let now = Date(timeIntervalSince1970: 1_792_065_600)   // 2026-10-15
        let inv = invoiceAnswer.suggestion(backend: "x", maxWords: 6, source: "t", now: now)
        #expect(inv.kind == .invoice && inv.merchant == "Bell Canada" && inv.total == "84-12" && inv.documentDate == "2026-10-12")
        #expect(inv.subject == "internet and tv bill")
        let stmt = DocumentPrompt.Answer(subject: "chequing statement", kind: "statement", issuer: "TD Bank", amount: "1200.00",
                                         date: "2026-09-30", confidence: 0.8).suggestion(backend: "x", maxWords: 6, source: "t", now: now)
        #expect(stmt.merchant == "TD Bank" && stmt.total == nil)
        let letter = DocumentPrompt.Answer(subject: "rent increase notice", kind: "letter", issuer: "Landlord Co", amount: "50",
                                           date: "2026-02-30", confidence: 0.8).suggestion(backend: "x", maxWords: 6, source: "t", now: now)
        #expect(letter.merchant == nil && letter.total == nil)
        #expect(letter.documentDate == nil)   // February 30th isn't a day
        let odd = DocumentPrompt.Answer(subject: "something", kind: "spreadsheet", confidence: 0.8).suggestion(backend: "x", maxWords: 6, source: "t", now: now)
        #expect(odd.kind == .other)
        #expect(DocumentPrompt.day("2031-01-01", now: now) == nil)   // more than two years ahead
        #expect(DocumentPrompt.day("2027-03-01", now: now) == "2027-03-01")   // a ticket for next spring
        #expect(DocumentPrompt.day("12/10/2026", now: now) == nil)
    }

    @Test func aPhotoAnswerOfOtherIsStillAPhoto() {
        // Adding PDF kinds (one of them "other") must not change how photos are read.
        let a = ClaudePrompt.Answer(subject: "blurry shape", kind: "other", merchant: "", total: "", confidence: 0.5, people_present: false)
        #expect(a.suggestion(context: PhotoContext(file: "/x.jpg", metadata: PhotoMetadata()), backend: "claude", maxWords: 6).kind == .photo)
        let b = ClaudePrompt.Answer(subject: "big bill", kind: "invoice", merchant: "", total: "", confidence: 0.5, people_present: false)
        #expect(b.suggestion(context: PhotoContext(file: "/x.jpg", metadata: PhotoMetadata()), backend: "claude", maxWords: 6).kind == .photo)
    }

    @Test func theContextNeverHasTheFileName() {
        let doc = DocumentText(text: "INVOICE", source: .ocr, pages: 3, title: "Invoice 83721")
        let c = DocumentPrompt.context(doc)
        #expect(c == "PDF worked out on the user's Mac:\n- pages: 3\n- text from: on-device OCR of page 1 (a scan; expect misread characters)\n- title in the PDF's metadata: Invoice 83721")
        #expect(DocumentPrompt.message(context: "C", text: "T") == "C\n\nText from the PDF (truncated):\n<<<\nT\n>>>")
    }
}

@Suite struct PDFNamingTests {
    @Test func invoiceAndLeaseNames() throws {
        let s = Sandbox()
        let inv = TestPDFs.text(s.file("document (3).pdf"), TestPDFs.invoiceLines)
        let lease = TestPDFs.scanned(s.file("scan0004.PDF"), TestPDFs.leaseLines)
        let p = pdfPlanner(s).plan([inv, lease])
        #expect(p.map(\.action) == [.rename, .rename])
        #expect(name(p[0]) == "2026-10-12_invoice_bell-canada_84-12.pdf")
        #expect(name(p[1]) == "2026-09-30_lease-agreement-45-carlton-st.PDF")   // the extension is kept as it was
        #expect(p[0].context?.metadata.dateSource == "document")
        #expect(p[1].context?.document?.source == .ocr)
    }

    @Test func templatesPerKind() throws {
        let p = Planner(config: Config(), places: nil)
        var ctx = PhotoContext(file: "/x/a.pdf", metadata: { var m = PhotoMetadata(); m.date = "2026-10-01"; return m }(), kind: .other)
        ctx.document = DocumentText(text: "x", source: .text, pages: 1)
        func stem(_ kind: Kind, _ subject: String, merchant: String? = nil, total: String? = nil) throws -> String {
            try p.compose(url: URL(fileURLWithPath: "/x/a.pdf"), context: ctx,
                          suggestion: NameSuggestion(kind: kind, subject: subject, merchant: merchant, total: total, confidence: 0.9, backend: "t")).0
        }
        #expect(try stem(.receipt, "online order", merchant: "Amazon", total: "42-00") == "2026-10-01_receipt_amazon_42-00")
        #expect(try stem(.statement, "chequing statement", merchant: "TD Bank") == "2026-10-01_statement_td-bank")
        #expect(try stem(.statement, "chequing statement") == "2026-10-01_statement_chequing-statement")
        #expect(try stem(.invoice, "web hosting") == "2026-10-01_invoice_web-hosting")   // no issuer or amount
        #expect(try stem(.ticket, "toronto to montreal train") == "2026-10-01_ticket_toronto-montreal-train")
        #expect(try stem(.paper, "attention is all you need") == "2026-10-01_paper_attention-all-you-need")
        #expect(try stem(.other, "dishwasher warranty card") == "2026-10-01_dishwasher-warranty-card")
    }

    @Test func freeLeavesPDFsAlone() throws {
        // Without Pro (or with "Name PDFs too" off) the planner and every watcher ignore PDFs, AirDropped or not.
        let s = Sandbox()
        let pdf = TestPDFs.text(s.file("document (3).pdf"), TestPDFs.invoiceLines)
        AirDropSim.tag(pdf)
        var free = s.planner()
        free.documentNamer = docNamer
        #expect(free.skipReason(pdf) == "not a supported image")
        let p = free.plan([pdf])
        #expect(p[0].action == .skip && p[0].context == nil)
        for intake in [Watcher.Options.Intake.airdrop, .all, .airdropAndScreenshots] {
            var o = Watcher.Options(folder: s.downloads)
            o.intake = intake
            var planner = pdfPlanner(s)
            planner.pdfs = true   // the watcher's own switch decides
            let w = Watcher(options: o, planner: planner, committer: s.committer(), startedAt: Date().addingTimeInterval(-60))
            #expect(w.scan().isEmpty)
            #expect(w.runOnce() == nil)
        }
        #expect(s.listing() == ["document (3).pdf"])
    }

    @Test func noModelMeansTheFileIsLeftAlone() throws {
        let s = Sandbox()
        let pdf = TestPDFs.text(s.file("invoice_83721.pdf"), TestPDFs.invoiceLines)
        let none = pdfPlanner(s, namer: nil).plan([pdf])[0]
        #expect(none.action == .skip)
        #expect(none.reason?.hasPrefix("left as it is: no engine on this Mac can name a PDF") == true)
        // Vision as the last resort doesn't guess either.
        let vision = pdfPlanner(s, namer: FallbackNamer(primary: FakeDocNamer { _ in nil }, fallback: VisionNamer())).plan([pdf])[0]
        #expect(vision.action == .skip)
        #expect(vision.reason?.contains("Apple Vision can't tell what a document is") == true)
        // An unsure answer is no name.
        let unsure = pdfPlanner(s, namer: FakeDocNamer { _ in DocumentPrompt.Answer(subject: "some page", kind: "other", confidence: 0.1) }).plan([pdf])[0]
        #expect(unsure.action == .skip)
        #expect(s.listing() == ["invoice_83721.pdf"])
    }

    @Test func safetySkips() throws {
        let s = Sandbox()
        let p = pdfPlanner(s)
        let downloading = TestPDFs.text(s.file("report.pdf"), TestPDFs.invoiceLines)
        try Data("partial".utf8).write(to: s.file("report.pdf.crdownload"))
        #expect(p.skipReason(downloading) == "still downloading")
        let placeholder = s.file("firefox.pdf")
        FileManager.default.createFile(atPath: placeholder.path, contents: Data())
        try Data("%PDF-1.4 partial".utf8).write(to: s.file("firefox.pdf.part"))
        #expect(p.skipReason(placeholder) == "still downloading")
        let whole = try Data(contentsOf: TestPDFs.text(s.root.path("whole.pdf"), TestPDFs.invoiceLines))
        try whole.prefix(whole.count / 2).write(to: s.file("cut.pdf"))
        #expect(p.skipReason(s.file("cut.pdf")) == "incomplete PDF")
        #expect(p.skipReason(TestPDFs.encrypted(s.file("statement.pdf"))) == "encrypted PDF")
        let app = s.file("Tool.app/Contents/Resources")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(p.skipReason(TestPDFs.text(app.appendingPathComponent("Manual.pdf"), ["User manual for the tool"])) == "inside an app bundle or package")
        let named = TestPDFs.text(s.file("2026-10-12_invoice_bell-canada_84-12.pdf"), TestPDFs.invoiceLines)
        #expect(p.skipReason(named) == "already has a date-first name")
        #expect(p.skipReason(TestPDFs.text(s.file("fine.pdf"), TestPDFs.invoiceLines)) == nil)
    }
}

/// The watchers with "Name PDFs too": what they pick up, the settle wait, one batch, undo.
@Suite(.serialized) struct PDFWatcherTests {
    func watcher(_ s: Sandbox, _ intake: Watcher.Options.Intake = .airdrop, startedAt: Date = Date().addingTimeInterval(-60)) -> Watcher {
        var o = Watcher.Options(folder: s.downloads)
        o.intake = intake
        o.pdfs = true
        o.settleInterval = 0.2; o.pdfSettleInterval = 0.4; o.quietWindow = 0.3; o.pollInterval = 0.05; o.maxWait = 20
        var planner = pdfPlanner(s)
        planner.namer = stemNamer
        return Watcher(options: o, planner: planner, committer: s.committer(), startedAt: startedAt)
    }

    @Test func airdropFolderTakesDownloadedPDFsOnly() {
        let s = Sandbox()
        AirDropSim.tag(TestPDFs.text(s.file("from safari.pdf"), TestPDFs.invoiceLines), agent: "com.apple.Safari")
        AirDropSim.tag(TestPDFs.text(s.file("airdropped.pdf"), TestPDFs.invoiceLines))
        TestPDFs.text(s.file("saved by an app.pdf"), TestPDFs.invoiceLines)        // no quarantine: made on this Mac
        // A sandboxed app's export is quarantined too, but without the download flag (seen on real files).
        let exported = TestPDFs.text(s.file("exported from preview.pdf"), TestPDFs.invoiceLines)
        try! Xattr.set(exported, "com.apple.quarantine", Data(AirDropSim.quarantine(agent: "Preview", flags: "0082").utf8))
        AirDropSim.tag(TestPDFs.text(s.file("old.pdf"), TestPDFs.invoiceLines), agent: "com.apple.Safari", at: Date().addingTimeInterval(-3600))
        TestImages.jpeg(s.file("browser photo.jpg"))                                  // images keep the AirDrop-only rule
        #expect(watcher(s).scan().map(\.lastPathComponent) == ["airdropped.pdf", "from safari.pdf"])
        #expect(watcher(s, .all).scan().map(\.lastPathComponent).sorted()
                == ["airdropped.pdf", "browser photo.jpg", "exported from preview.pdf", "from safari.pdf", "saved by an app.pdf"])
        #expect(watcher(s, .screenshots).scan().isEmpty)
        var airdropOnly = pdfPlanner(s)
        airdropOnly.airdropOnly = true
        #expect(airdropOnly.skipReason(exported) == "not downloaded or AirDropped")
        #expect(airdropOnly.skipReason(s.file("from safari.pdf")) == nil)
    }

    @Test func waitsForTheDownloadThenNamesAndUndoes() throws {
        let s = Sandbox()
        let w = watcher(s)
        let url = s.file("document (3).pdf")
        let data = try Data(contentsOf: TestPDFs.text(s.root.path("src.pdf"), TestPDFs.invoiceLines))
        // A browser that writes the final name in bursts, next to a .crdownload, for ~0.6 s.
        try Data("partial".utf8).write(to: s.file("document (3).pdf.crdownload"))
        let writer = AirDropSim.slowWrite(data, to: url, chunk: max(1, data.count / 6), pause: 0.1, agent: "com.google.Chrome")
        let remover = Thread {
            while !writer.isFinished { Thread.sleep(forTimeInterval: 0.02) }
            Thread.sleep(forTimeInterval: 0.3)
            try? FileManager.default.removeItem(at: s.file("document (3).pdf.crdownload"))
        }
        remover.start()
        // Like WatchService on each folder event: nothing is a candidate while the .crdownload is there.
        var found: Watcher.Batch?
        let deadline = Date().addingTimeInterval(15)
        while found == nil && Date() < deadline {
            found = w.runOnce()
            if found == nil {
                #expect(s.listing().contains("document (3).pdf"))
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let batch = try #require(found)
        #expect(writer.isFinished)
        #expect(!FileManager.default.fileExists(atPath: s.file("document (3).pdf.crdownload").path))
        #expect(batch.pdfs == 1 && batch.photos == 0 && batch.failed == 0)
        #expect(Watcher.summary(batch) == "Renamed 1 PDF")
        #expect(s.listing() == ["2026-10-12_invoice_bell-canada_84-12.pdf"])
        #expect(try Data(contentsOf: s.file("2026-10-12_invoice_bell-canada_84-12.pdf")) == data)   // renamed, not rewritten
        // The journal keeps what "Export Receipts as CSV" needs.
        let rec = try #require(s.journal.records().first { $0.op == .done })
        #expect(rec.receipt == .init(date: "2026-10-12", merchant: "Bell Canada", total: "84-12"))
        #expect(rec.summary == "invoice: internet and tv bill")

        let undone = try s.undoer().undo(.batch(batch.id))
        #expect(undone.map(\.status) == [.restored])
        #expect(s.listing() == ["document (3).pdf"])
        #expect(w.runOnce() == nil)   // not renamed straight back
    }

    @Test func aPDFAndPhotosInOneBatch() throws {
        let s = Sandbox()
        let w = watcher(s)
        AirDropSim.tag(TestImages.heic(s.file("IMG_1.HEIC")))
        AirDropSim.tag(TestPDFs.text(s.file("scan0004.pdf"), TestPDFs.leaseLines), agent: "com.apple.mail")
        let batch = try #require(w.runOnce())
        #expect(Watcher.summary(batch) == "Renamed 1 photo and 1 PDF")
        #expect(s.listing() == ["2026-09-21_toronto_subject-img-1.jpg", "2026-09-30_lease-agreement-45-carlton-st.pdf"])
    }
}

@Suite(.serialized) struct PDFEngineTests {
    let doc = DocumentText(text: TestPDFs.invoiceLines.joined(separator: "\n"), source: .text, pages: 1, title: "Invoice 83721")
    var ctx: PhotoContext { PhotoContext(file: "/Users/me/Downloads/document (3).pdf", metadata: PhotoMetadata(), kind: .other, document: doc) }
    static let answer = #"{"subject":"internet and tv bill","kind":"invoice","issuer":"Bell Canada","amount":"84.12","date":"2026-10-12","confidence":0.9}"#

    @Test func claudeGetsTextOnly() throws {
        ClaudeNamer.structuredOutput.value = true
        StubURLProtocol.reset([.init(status: 200, body: message(Self.answer, input: 1100, output: 50))])
        var n = ClaudeNamer(auth: ClaudeAuth(environment: ["ANTHROPIC_API_KEY": "sk-ant-test-key"], storedKey: { nil }, antPath: { nil }),
                            transport: StubURLProtocol.transport)
        n.sleep = { _ in }
        let s = try n.suggest(for: URL(fileURLWithPath: ctx.file), context: ctx)
        #expect(s.kind == .invoice && s.merchant == "Bell Canada" && s.total == "84-12" && s.documentDate == "2026-10-12")
        #expect(s.usage?.inputTokens == 1100)
        let (_, body) = try #require(StubURLProtocol.captured.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let content = try #require(((json["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        #expect(content.count == 1 && content[0]["type"] as? String == "text")
        let text = try #require(content[0]["text"] as? String)
        #expect(text.contains("Bell Canada") && text.hasPrefix(DocumentPrompt.contextPrefix))
        #expect(!text.contains("document (3)") && !text.contains("/Users/"))
        #expect(json["system"] as? String == DocumentPrompt.instructions + DocumentPrompt.jsonInstructions)
        #expect(!String(decoding: body, as: UTF8.self).contains("\"image\""))
    }

    @Test func hostedUsesNameTextAndSharesTheCount() throws {
        HostedNamer.blocks.reset(); HostedNamer.usage.reset()
        HostedStubProtocol.reset([.init(status: 200, body: Self.answer, headers: ["x-names-remaining": "41", "x-names-reset": "2026-11-01T00:00:00Z"])])
        var n = HostedNamer(license: FixedLicense(key: HostedNamerTests.key), transport: HostedStubProtocol.transport)
        n.sleep = { _ in }
        let s = try n.suggest(for: URL(fileURLWithPath: ctx.file), context: ctx)
        #expect(s.kind == .invoice && s.backend == "hosted" && s.documentDate == "2026-10-12")
        #expect(HostedNamer.lastUsage()?.remaining == 41)
        let (req, body) = try #require(HostedStubProtocol.captured.first)
        #expect(req.url?.path == "/v1/name-text")
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer \(HostedNamerTests.key)")
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(Set(json.keys) == ["context", "text"])
        #expect(json["context"] == DocumentPrompt.context(doc) && json["text"] == doc.text)
    }

    @Test func hostedMonthlyLimitFallsBackToAppleIntelligence() throws {
        HostedNamer.blocks.reset(); HostedNamer.usage.reset()
        HostedStubProtocol.reset([.init(status: 429, body: hostedError("monthly_limit", "used up", resets: "2026-11-01T00:00:00Z"))])
        var hosted = HostedNamer(license: FixedLicense(key: HostedNamerTests.key), transport: HostedStubProtocol.transport)
        hosted.sleep = { _ in }
        var apple = AppleFMNamer()
        apple.status = { .available }
        apple.generateDocument = { prompt, _ in
            #expect(prompt.hasPrefix(DocumentPrompt.contextPrefix) && prompt.contains("Bell Canada"))
            return DocumentPrompt.Answer(subject: "bell internet bill", kind: "invoice", issuer: "Bell", amount: "84.12", date: "2026-10-12", confidence: 0.7)
        }
        let s = try FallbackNamer(primary: hosted, fallback: apple).suggest(for: URL(fileURLWithPath: ctx.file), context: ctx)
        #expect(s.backend == "apple" && s.subject == "bell internet bill")
        #expect(s.fallbackFrom?.contains("monthly hosted limit") == true)
    }

    @Test func documentEngineChoice() {
        let key = ClaudeAuth(environment: ["ANTHROPIC_API_KEY": "sk-ant-x"], storedKey: { nil }, antPath: { nil })
        let noKey = ClaudeAuth(environment: [:], storedKey: { nil }, antPath: { nil })
        var ready = AppleFMNamer(); ready.status = { .available }
        var off = AppleFMNamer(); off.status = { .notEnabled }
        let pro = FixedLicense(key: "BA_X")
        func chain(_ id: String, _ auth: ClaudeAuth, _ apple: AppleFMNamer, _ license: any LicenseKeySource = NoLicenseKey(),
                   _ config: Config = Config()) -> String {
            guard let n = Backends.resolveDocuments(id, config: config, auth: auth, apple: apple, license: license) else { return "none" }
            if let f = n as? FallbackNamer { return "\(f.primary.id)>\(f.fallback.id)" }
            return n.id
        }
        #expect(chain("auto", key, ready) == "claude>apple")
        #expect(chain("auto", key, off) == "claude")
        #expect(chain("auto", noKey, ready, pro) == "hosted>apple")
        #expect(chain("auto", noKey, ready) == "apple")
        #expect(chain("auto", noKey, off) == "none")
        var local = Config(); local.claudeInAuto = false
        #expect(chain("auto", key, off, pro, local) == "none")
        #expect(chain("vision", key, ready) == "apple")   // on-device stays on-device
        #expect(chain("vision", key, off) == "none")
        #expect(chain("hosted", noKey, off, pro) == "hosted")
    }

    @Test func configKey() throws {
        #expect(Config().namePDFs)
        let c = try Config.parse("name_pdfs = false")
        #expect(!c.namePDFs)
        #expect(try Config.parse(c.rendered(updating: nil)) == c)
        #expect(!Config().rendered(updating: nil).contains("name_pdfs"))
        #expect(Config().kindTemplates["invoice"] == "{date}_invoice_{merchant}_{total}")
        #expect(try Config.parse("[file]\ninvoice = \"~/Documents/Invoices\"").fileFolders["invoice"] == "~/Documents/Invoices")
    }

    @Test func workerPromptMatchesTheApp() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("hosted/src/prompt-text.json"))
        let p = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(p["system"] as? String == DocumentPrompt.instructions, "update hosted/src/prompt-text.json's system from DocumentPrompt.instructions")
        #expect(p["json_instructions"] as? String == DocumentPrompt.jsonInstructions)
        #expect(p["context_prefix"] as? String == DocumentPrompt.contextPrefix)
        #expect(p["kinds"] as? [String] == DocumentPrompt.kinds)
        #expect(NSDictionary(dictionary: p["schema"] as? [String: Any] ?? [:]).isEqual(to: DocumentPrompt.schema))
    }
}
