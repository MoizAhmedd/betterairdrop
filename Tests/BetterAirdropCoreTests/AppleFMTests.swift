@testable import BetterAirdropCore
import Foundation
import Testing

/// The Apple Intelligence backend without the model: status messages, the prompt, and turning an
/// answer into a name. The FoundationModels call itself is replaced by `generate`.
@Suite struct AppleFMTests {
    typealias Answer = ClaudePrompt.Answer

    func namer(_ status: AppleIntelligenceStatus = .available,
               _ generate: @escaping @Sendable (String) throws -> Answer = { _ in Answer(subject: "x y", kind: "photo", confidence: 1) }) -> AppleFMNamer {
        var n = AppleFMNamer()
        n.status = { status }
        n.generate = { prompt, _ in try generate(prompt) }
        return n
    }

    func context(_ vision: VisionResult? = VisionResult(labels: [.init("lamp", 0.7), .init("structure", 0.2)],
                                                        lines: [.init("IKEA", confidence: 0.9, height: 0.05)]),
                 kind: Kind = .photo, meta: PhotoMetadata = PhotoMetadata()) -> PhotoContext {
        var m = meta
        m.date = m.date ?? "2026-09-21"
        m.latitude = 43.6532; m.longitude = -79.3832
        return PhotoContext(file: "/Users/someone/Downloads/IMG_4821.HEIC", metadata: m,
                            place: Place(city: "Toronto", countryCode: "CA", distanceKm: 3),
                            vision: vision, kind: kind, kindReason: "default")
    }

    let url = URL(fileURLWithPath: "/Users/someone/Downloads/IMG_4821.HEIC")

    // MARK: Availability

    @Test func everyUnavailableReasonSaysWhatToDo() {
        #expect(AppleIntelligenceStatus.osTooOld("15.4").message == "Needs macOS 26 or later with Apple Intelligence. This Mac runs macOS 15.4.")
        #expect(AppleIntelligenceStatus.notEnabled.message.contains("System Settings → Apple Intelligence & Siri"))
        #expect(AppleIntelligenceStatus.deviceNotEligible.message.contains("Apple silicon"))
        #expect(AppleIntelligenceStatus.modelNotReady.message.contains("downloading"))
        #expect(AppleIntelligenceStatus.notInThisBuild.message.contains("Xcode 26"))
        #expect(AppleIntelligenceStatus.unknown("newReason").message.contains("newReason"))
        for s: AppleIntelligenceStatus in [.osTooOld("15.4"), .notEnabled, .deviceNotEligible, .modelNotReady, .notInThisBuild, .unknown("x")] {
            #expect(!s.isAvailable)
            #expect(!s.message.contains("27"), "no stale macOS 27 requirement")
        }
        #expect(AppleIntelligenceStatus.available.isAvailable)
    }

    @Test func settingsLinkOnlyWhenSettingsCanFixIt() {
        #expect(AppleIntelligenceStatus.notEnabled.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.Siri-Settings.extension")
        #expect(AppleIntelligenceStatus.modelNotReady.settingsURL != nil)
        for s: AppleIntelligenceStatus in [.available, .osTooOld("15.4"), .deviceNotEligible, .notInThisBuild, .unknown("x")] {
            #expect(s.settingsURL == nil)
        }
    }

    @Test func availabilityCarriesTheReason() {
        #expect(namer(.available).availability() == .ready)
        #expect(namer(.notEnabled).availability() == .unavailable(AppleIntelligenceStatus.notEnabled.message))
        #expect(namer(.modelNotReady).availability() == .unavailable(AppleIntelligenceStatus.modelNotReady.message))
    }

    /// On this machine's SDK and OS: never "ready" unless the model really is.
    @Test func currentStatusMatchesThisBuild() {
        let s = AppleIntelligenceStatus.current
        #if !canImport(FoundationModels)
        #expect(!s.isAvailable)
        if #unavailable(macOS 26) { #expect(s == .osTooOld(AppleIntelligenceStatus.osVersion)) }
        #endif
        #expect(AppleFMNamer().availability() == (s.isAvailable ? .ready : .unavailable(s.message)))
    }

    @Test func autoAndExplicitApple() throws {
        let key = ClaudeAuth(environment: ["ANTHROPIC_API_KEY": "sk-ant-test-key"], storedKey: { nil }, antPath: { nil })
        // Ready: auto picks it over Claude, wrapped so Vision names what it can't.
        let auto = try Backends.resolve("auto", auth: key, apple: namer(.available))
        #expect(auto.id == "apple" && (auto as? FallbackNamer)?.fallback.id == "vision")
        #expect(try Backends.resolve("apple", auth: .none, apple: namer(.available)) is FallbackNamer)
        // Not ready: auto moves on; an explicit choice says why.
        #expect(try Backends.resolve("auto", auth: key, apple: namer(.notEnabled)).id == "claude")
        #expect(try Backends.resolve("auto", auth: .none, apple: namer(.notEnabled)).id == "vision")
        #expect(throws: BackendError.unavailable("apple", reason: AppleIntelligenceStatus.notEnabled.message)) {
            try Backends.resolve("apple", auth: .none, apple: namer(.notEnabled))
        }
    }

    // MARK: Prompt

    @Test func promptIsVisionsFindingsAndContextOnly() {
        let p = AppleFMPrompt.prompt(context(kind: .photo))
        #expect(p.contains("- on-device labels: lamp 0.70"))
        #expect(!p.contains("structure"), "labels under 0.3 are left out")
        #expect(p.contains("\"IKEA\""))
        #expect(p.contains("- local kind guess: photo (default)"))
        #expect(p.contains("- place: Toronto, CA (city only)"))
        #expect(p.contains("- captured: 2026-09-21"))
        #expect(!p.contains("IMG_4821") && !p.contains("43.65") && !p.contains("79.38"), "no file name or coordinates")
        #expect(p == ClaudePrompt.context(context(kind: .photo)), "the same context Claude gets")
    }

    @Test func instructionsShareClaudesSubjectRules() {
        #expect(AppleFMPrompt.instructions.contains("can't see the image"))
        #expect(AppleFMPrompt.instructions.hasSuffix(ClaudePrompt.subjectRules))
        #expect(ClaudePrompt.instructions.contains(ClaudePrompt.subjectRules))
        #expect(ClaudePrompt.subjectRules.hasPrefix("Rules for \"subject\":"))
    }

    @Test func evidenceNeedsALabelOrText() {
        #expect(!AppleFMPrompt.hasEvidence(context(nil)))
        #expect(!AppleFMPrompt.hasEvidence(context(VisionResult(labels: [.init("structure", 0.2)]))))
        #expect(!AppleFMPrompt.hasEvidence(context(VisionResult(lines: [.init("12:41", confidence: 0.9)]))), "no letters")
        #expect(AppleFMPrompt.hasEvidence(context(VisionResult(labels: [.init("lamp", 0.3)]))))
        #expect(AppleFMPrompt.hasEvidence(context(VisionResult(lines: [.init("Failed payment", confidence: 0.9)]))))
    }

    // MARK: Answer → name

    @Test func answerBecomesACleanSubject() throws {
        let seen = PromptLog()
        let n = namer(.available) { p in
            seen.add(p)
            return Answer(subject: "A photo of Toronto skyline at dusk.", kind: "photo", merchant: "", total: "", confidence: 0.8)
        }
        let s = try n.suggest(for: url, context: context())
        #expect(s.subject == "skyline at dusk")
        #expect(s.backend == "apple" && s.kind == .photo && s.confidence == 0.8)
        #expect(s.merchant == nil && s.total == nil && s.usage == nil)
        #expect(s.why.first?.contains("no pixels") == true)
        #expect(s.why.contains { $0.contains("from Apple Intelligence") })
        #expect(s.timings?[.apple] != nil)
        #expect(seen.prompts == [AppleFMPrompt.prompt(context())])
    }

    @Test func receiptsAndScreenshots() throws {
        let receipt = try namer(.available) { _ in
            Answer(subject: "grocery receipt", kind: "receipt", merchant: " Loblaws ", total: "84.12", confidence: 0.9)
        }.suggest(for: url, context: context())
        #expect(receipt.kind == .receipt && receipt.merchant == "Loblaws" && receipt.total == "84-12")

        var shot = PhotoMetadata(); shot.userComment = "Screenshot"
        let s = try namer(.available) { _ in Answer(subject: "failed payment notice", kind: "document", confidence: 0.9) }
            .suggest(for: url, context: context(kind: .screenshot, meta: shot))
        #expect(s.kind == .screenshot, "metadata says screenshot, so it stays one")
        #expect(s.why.contains { $0.contains("Apple Intelligence said document") })
    }

    @Test func unusableAnswersAreErrors() {
        #expect(throws: AppleFMNamer.Error.badOutput("unknown kind panorama")) {
            try namer(.available) { _ in Answer(subject: "x y", kind: "panorama", confidence: 1) }.suggest(for: url, context: context())
        }
        #expect(throws: AppleFMNamer.Error.badOutput("empty subject")) {
            try namer(.available) { _ in Answer(subject: " ", kind: "photo", confidence: 1) }.suggest(for: url, context: context())
        }
        #expect(throws: AppleFMNamer.Error.model("guardrail")) {
            try namer(.available) { _ in throw AppleFMNamer.Error.model("guardrail") }.suggest(for: url, context: context())
        }
    }

    @Test func noEvidenceSkipsTheModel() {
        let seen = PromptLog()
        #expect(throws: AppleFMNamer.Error.noEvidence) {
            try namer(.available) { seen.add($0); return Answer(subject: "x y", kind: "photo", confidence: 1) }
                .suggest(for: url, context: context(VisionResult(labels: [.init("structure", 0.1)])))
        }
        #expect(seen.prompts.isEmpty)
    }

    @Test func failuresFallBackToVision() throws {
        let fb = FallbackNamer(primary: namer(.available) { _ in throw AppleFMNamer.Error.timeout(30) }, fallback: VisionNamer())
        let s = try fb.suggest(for: url, context: context(VisionResult(labels: [.init("lamp", 0.7)])))
        #expect(s.backend == "vision" && s.subject == "lamp")
        #expect(s.fallbackFrom == "apple: Apple Intelligence didn't answer within 30 s")
    }

    @Test func nameEndToEnd() throws {
        let n = namer(.available) { _ in Answer(subject: "Walnut lamp on the oak sideboard", kind: "photo", confidence: 0.8) }
        let ctx = context()
        let s = try n.suggest(for: url, context: ctx)
        let (stem, _, _) = try Planner(config: Config(), places: nil).compose(url: url, context: ctx, suggestion: s)
        #expect(stem == "2026-09-21_toronto_walnut-lamp-oak-sideboard")
    }

    final class PromptLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ p: String) { lock.lock(); items.append(p); lock.unlock() }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
