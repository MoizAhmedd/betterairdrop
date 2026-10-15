import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple Intelligence can name photos on this Mac, and if not, why. Read from
/// `SystemLanguageModel.default.availability` on macOS 26+; the rest of this type doesn't need
/// FoundationModels, so the messages are unit-tested on any SDK.
public enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    /// Older than macOS 26. Carries the running version ("15.4").
    case osTooOld(String)
    /// macOS 26+, but this binary was built with an SDK that has no FoundationModels (Xcode < 26).
    case notInThisBuild
    /// Not an Apple silicon Mac (or a VM): Apple Intelligence can't run here at all.
    case deviceNotEligible
    /// Supported, but Apple Intelligence is turned off in System Settings.
    case notEnabled
    /// Turned on, but the model isn't on the Mac yet (still downloading or being set up).
    case modelNotReady
    /// A reason added after macOS 26 that this build doesn't know about.
    case unknown(String)

    public var isAvailable: Bool { self == .available }

    /// What the user sees: the reason, and what to do about it.
    public var message: String {
        switch self {
        case .available: "Apple Intelligence is ready."
        case .osTooOld(let v): "Needs macOS 26 or later with Apple Intelligence. This Mac runs macOS \(v)."
        case .notInThisBuild: "This copy of BetterAirdrop was built without Apple Intelligence support (it needs Xcode 26 or later). Update BetterAirdrop."
        case .deviceNotEligible: "This Mac can't run Apple Intelligence. It needs a Mac with Apple silicon (M1 or later)."
        case .notEnabled: "Apple Intelligence is off. Turn it on in System Settings → Apple Intelligence & Siri."
        case .modelNotReady: "Apple Intelligence is still getting ready (the model may be downloading). Try again in a few minutes."
        case .unknown(let why): "Apple Intelligence isn't available on this Mac (\(why))."
        }
    }

    /// The System Settings pane that fixes it, if there is one. "Apple Intelligence & Siri" is the
    /// `com.apple.Siri-Settings.extension` pane.
    public var settingsURL: URL? {
        switch self {
        case .notEnabled, .modelNotReady: Self.settingsPane
        default: nil
        }
    }

    public static let settingsPane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    /// This Mac, now. Cheap: safe to call whenever a view is drawn.
    public static var current: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .unknown(String(describing: reason))
                }
            }
        }
        #else
        if #available(macOS 26, *) {
            // An Intel slice may be built without FoundationModels; Intel Macs can't run it anyway.
            #if arch(x86_64)
            return .deviceNotEligible
            #else
            return .notInThisBuild
            #endif
        }
        #endif
        return .osTooOld(osVersion)
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// Apple's on-device Foundation Models (macOS 26+ with Apple Intelligence on).
///
/// The on-device model reads text only, so it names the photo from what Vision already found on
/// this Mac (labels, OCR text, the kind guess) plus the date/city context: the same text context
/// Claude gets (`ClaudePrompt.context`), and the same subject rules. Nothing leaves the Mac.
/// Guided generation (`@Generable`) fixes the answer's shape, and the answer is checked and
/// cleaned with Claude's code (`ClaudePrompt.problem`, `Answer.suggestion`).
public struct AppleFMNamer: Namer {
    public let id = "apple"
    /// Longest wait for one answer (the first request also loads the model).
    public var timeout: TimeInterval = 30
    /// Injected in tests: this Mac's status, and the model call (prompt → answer).
    var status: @Sendable () -> AppleIntelligenceStatus = { AppleIntelligenceStatus.current }
    var generate: @Sendable (_ prompt: String, _ timeout: TimeInterval) throws -> ClaudePrompt.Answer = {
        try AppleFMNamer.onDevice($0, timeout: $1)
    }
    /// The model call for a PDF's text (prompt → answer).
    var generateDocument: @Sendable (_ prompt: String, _ timeout: TimeInterval) throws -> DocumentPrompt.Answer = {
        try AppleFMNamer.onDeviceDocument($0, timeout: $1)
    }

    public init() {}

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case noEvidence
        case unavailable(String)
        case timeout(TimeInterval)
        case model(String)
        case badOutput(String)

        public var description: String {
            switch self {
            case .noEvidence: "Vision found no label or text to describe, so there was nothing to ask Apple Intelligence"
            case .unavailable(let why): why
            case .timeout(let s): "Apple Intelligence didn't answer within \(Int(s)) s"
            case .model(let why): "Apple Intelligence failed: \(why)"
            case .badOutput(let why): "Apple Intelligence's answer wasn't usable: \(why)"
            }
        }
    }

    public func availability() -> Availability {
        let s = status()
        return s.isAvailable ? .ready : .unavailable(s.message)
    }

    public func suggest(for url: URL, context ctx: PhotoContext) throws -> NameSuggestion {
        if let doc = ctx.document { return try suggestDocument(doc) }
        // Without labels or text the model would only be guessing from the date and city.
        guard AppleFMPrompt.hasEvidence(ctx) else { throw Error.noEvidence }
        var timings = StageTimings()
        let answer = try timings.time(.apple) { try generate(AppleFMPrompt.prompt(ctx), timeout) }
        if let why = ClaudePrompt.problem(with: answer) { throw Error.badOutput(why) }
        var s = answer.suggestion(context: ctx, backend: id, maxWords: 6, source: "Apple Intelligence")
        s.timings = timings
        s.why.insert("sent Vision's labels and text and the context (no pixels) to Apple Intelligence on this Mac", at: 0)
        return s
    }

    /// A PDF's text is what the on-device model reads best: it gets the same context and text Claude does.
    func suggestDocument(_ doc: DocumentText) throws -> NameSuggestion {
        var timings = StageTimings()
        let prompt = DocumentPrompt.message(context: DocumentPrompt.context(doc), text: String(doc.text.prefix(AppleFMPrompt.maxDocumentChars)))
        let answer = try timings.time(.apple) { try generateDocument(prompt, timeout) }
        if let why = DocumentPrompt.problem(with: answer) { throw Error.badOutput(why) }
        var s = answer.suggestion(backend: id, maxWords: 6, source: "Apple Intelligence")
        s.timings = timings
        s.why.insert("sent the PDF's text (\(doc.source == .ocr ? "OCR of page 1" : "text layer")) to Apple Intelligence on this Mac", at: 0)
        return s
    }

    static func onDevice(_ prompt: String, timeout: TimeInterval) throws -> ClaudePrompt.Answer {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return try AppleFMSession.respond(prompt, timeout: timeout) }
        #endif
        throw Error.unavailable(AppleIntelligenceStatus.current.message)
    }

    static func onDeviceDocument(_ prompt: String, timeout: TimeInterval) throws -> DocumentPrompt.Answer {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return try AppleFMSession.respondDocument(prompt, timeout: timeout) }
        #endif
        throw Error.unavailable(AppleIntelligenceStatus.current.message)
    }
}

/// The instructions and prompt for the on-device model.
public enum AppleFMPrompt {
    static let instructions = """
    You name image files, but you can't see the image. You get what an on-device scan of it found: \
    labels for what it shows (each with a score from 0 to 1), text read from it, and a guess at the \
    kind of image. Using only that evidence, describe the image's main subject as a short filename \
    phrase. Don't invent details the evidence doesn't support. When the evidence is thin, keep the \
    phrase short and give a low confidence.


    """ + ClaudePrompt.subjectRules

    /// The same text context Claude gets: date, city, device, kind guess, labels and an OCR snippet.
    /// Never coordinates or the file name.
    public static func prompt(_ ctx: PhotoContext) -> String { ClaudePrompt.context(ctx) }

    /// The on-device model's context is about 4,000 tokens for instructions, prompt and answer
    /// together; 3,000 characters of text (about 800 tokens) leaves plenty of room.
    static let maxDocumentChars = 3000

    /// The instructions for a PDF: the same rules Claude gets (`DocumentPrompt`).
    static let documentInstructions = DocumentPrompt.instructions

    /// True when Vision found something to go on: a label scoring 0.3 or more, or confident text.
    static func hasEvidence(_ ctx: PhotoContext) -> Bool {
        guard let v = ctx.vision else { return false }
        return v.labels.contains { $0.confidence >= 0.3 } || !ClaudePrompt.ocrSnippet(v, limit: 300).isEmpty
    }
}

#if canImport(FoundationModels)
/// The answer's shape, enforced by guided generation. Kind comes first so the subject is written
/// knowing it. The kinds are `ClaudePrompt.kinds`.
@available(macOS 26, *)
@Generable
struct AppleFMAnswer {
    @Guide(description: "What kind of image this is", .anyOf(["photo", "screenshot", "receipt", "document", "whiteboard", "other"]))
    var kind: String
    @Guide(description: "2 to 6 lowercase words naming the image's main subject, like \"walnut lamp on oak sideboard\" or \"weekly weather forecast\"")
    var subject: String
    @Guide(description: "For a receipt, the store name in 1 to 3 words; otherwise empty")
    var merchant: String
    @Guide(description: "For a receipt, the total paid as digits like 84.12; otherwise empty")
    var total: String
    @Guide(description: "How sure you are, from 0 to 1, that the subject describes the image", .range(0.0...1.0))
    var confidence: Double
}

/// A PDF's answer, with the same fields as `DocumentPrompt.Answer`. The kinds are `DocumentPrompt.kinds`.
@available(macOS 26, *)
@Generable
struct AppleFMDocumentAnswer {
    @Guide(description: "What kind of document this is", .anyOf(["invoice", "receipt", "statement", "contract", "form", "letter", "ticket", "manual", "paper", "other"]))
    var kind: String
    @Guide(description: "2 to 6 lowercase words naming the document, like \"internet and tv bill\" or \"lease agreement 45 carlton st\"")
    var subject: String
    @Guide(description: "The company or organisation that issued it, in 1 to 3 words; empty if none")
    var issuer: String
    @Guide(description: "For an invoice or receipt, the total as digits like 84.12; otherwise empty")
    var amount: String
    @Guide(description: "The document's own date as YYYY-MM-DD; empty if the text has none")
    var date: String
    @Guide(description: "How sure you are, from 0 to 1, that the subject describes the document", .range(0.0...1.0))
    var confidence: Double
}

@available(macOS 26, *)
enum AppleFMSession {
    /// One request at a time: the model runs on one Neural Engine, so parallel requests (the planner
    /// names four photos at once) would only queue behind each other and eat into their timeouts.
    static let gate = NSLock()

    final class Box: @unchecked Sendable { var result: Result<ClaudePrompt.Answer, any Error>? }

    /// Runs one request on a fresh session and waits for it (the `Namer` API is synchronous and is
    /// called on GCD threads, never on the main thread or the concurrency pool).
    static func respond(_ prompt: String, timeout: TimeInterval) throws -> ClaudePrompt.Answer {
        gate.lock(); defer { gate.unlock() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                let session = LanguageModelSession(instructions: AppleFMPrompt.instructions)
                let response = try await session.respond(to: prompt, generating: AppleFMAnswer.self,
                                                         options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200))
                let a = response.content
                box.result = .success(ClaudePrompt.Answer(subject: a.subject, kind: a.kind, merchant: a.merchant,
                                                          total: a.total, confidence: a.confidence, people_present: nil))
            } catch {
                box.result = .failure(AppleFMNamer.Error.model((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw AppleFMNamer.Error.timeout(timeout)
        }
        return try box.result!.get()
    }

    final class DocumentBox: @unchecked Sendable { var result: Result<DocumentPrompt.Answer, any Error>? }

    /// `respond`, for a PDF's text.
    static func respondDocument(_ prompt: String, timeout: TimeInterval) throws -> DocumentPrompt.Answer {
        gate.lock(); defer { gate.unlock() }
        let box = DocumentBox()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                let session = LanguageModelSession(instructions: AppleFMPrompt.documentInstructions)
                let response = try await session.respond(to: prompt, generating: AppleFMDocumentAnswer.self,
                                                         options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200))
                let a = response.content
                box.result = .success(DocumentPrompt.Answer(subject: a.subject, kind: a.kind, issuer: a.issuer,
                                                            amount: a.amount, date: a.date, confidence: a.confidence))
            } catch {
                box.result = .failure(AppleFMNamer.Error.model((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw AppleFMNamer.Error.timeout(timeout)
        }
        return try box.result!.get()
    }
}
#endif
