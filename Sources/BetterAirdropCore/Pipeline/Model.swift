import Foundation

public enum Kind: String, Codable, Sendable, CaseIterable {
    case photo, screenshot, receipt, document, whiteboard
    /// PDF kinds (Pro, "Name PDFs too"). `receipt` is shared with photos.
    case invoice, statement, contract, form, letter, ticket, manual, paper, other

    /// What an image can be. An image namer's answer outside these is read as `photo`.
    public static let imageKinds: [Kind] = [.photo, .screenshot, .receipt, .document, .whiteboard]
    /// What a PDF can be. A PDF namer's answer outside these is read as `other`.
    public static let pdfKinds: [Kind] = [.invoice, .receipt, .statement, .contract, .form, .letter, .ticket, .manual, .paper, .other]
}

/// Text read from a PDF on this Mac (`PDFText`): the namer gets this, never the file or a page image.
public struct DocumentText: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// The PDF's own text layer (first pages).
        case text
        /// No text layer (a scan): page 1 rendered and read with on-device Vision OCR.
        case ocr
    }
    /// At most `PDFText.maxChars` UTF-16 units, whitespace collapsed.
    public var text: String
    public var source: Source
    public var pages: Int
    /// The title in the PDF's metadata, when it looks like a real title.
    public var title: String?
    /// The PDF's creation date (`YYYY-MM-DD`), from its metadata.
    public var created: String?

    public init(text: String, source: Source, pages: Int, title: String? = nil, created: String? = nil) {
        self.text = text; self.source = source; self.pages = pages; self.title = title; self.created = created
    }
}

/// Everything worked out locally about one photo, before any namer runs.
public struct PhotoContext: Codable, Sendable {
    public var file: String
    public var metadata: PhotoMetadata
    public var place: Place?
    public var airdrop: Bool
    public var vision: VisionResult?
    public var kind: Kind
    public var kindReason: String
    /// Set for a PDF: its text, which is all a namer gets. Nil for images.
    public var document: DocumentText?

    public init(file: String, metadata: PhotoMetadata, place: Place? = nil, airdrop: Bool = false,
                vision: VisionResult? = nil, kind: Kind = .photo, kindReason: String = "default", document: DocumentText? = nil) {
        self.file = file; self.metadata = metadata; self.place = place; self.airdrop = airdrop
        self.vision = vision; self.kind = kind; self.kindReason = kindReason; self.document = document
    }
}

/// What a namer backend returns. Only the subject (and receipt fields) come from the model;
/// date, place and kind are decided locally.
public struct NameSuggestion: Codable, Sendable, Equatable {
    public var kind: Kind
    public var subject: String
    public var merchant: String?
    public var total: String?
    /// PDFs: the document's own date (`YYYY-MM-DD`) as the namer read it, preferred over the file's date.
    public var documentDate: String?
    public var confidence: Double
    public var backend: String
    /// Short human-readable trail for `explain`.
    public var why: [String]
    /// Tokens a cloud backend used for this photo (nil for on-device backends).
    public var usage: TokenUsage?
    /// Set when the chosen backend failed and another one produced this name: why the first failed.
    public var fallbackFrom: String?
    /// Time spent naming (credential, encode, Claude request) for `explain` and the perf log.
    public var timings: StageTimings?

    public init(kind: Kind, subject: String, merchant: String? = nil, total: String? = nil,
                confidence: Double, backend: String, why: [String] = [], usage: TokenUsage? = nil) {
        self.kind = kind; self.subject = subject; self.merchant = merchant; self.total = total
        self.confidence = confidence; self.backend = backend; self.why = why; self.usage = usage
    }
}

/// Token counts reported by a cloud API for one request (all attempts summed).
public struct TokenUsage: Codable, Sendable, Equatable {
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public init(model: String, inputTokens: Int, outputTokens: Int) {
        self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }

    /// US dollars at the given per-million-token prices (Haiku 4.5: $1 in, $5 out).
    public func cost(inputPerMillion: Double = 1, outputPerMillion: Double = 5) -> Double {
        Double(inputTokens) / 1e6 * inputPerMillion + Double(outputTokens) / 1e6 * outputPerMillion
    }
}

public enum Availability: Sendable, Equatable {
    case ready
    case unavailable(String)
}

/// A naming backend. See PLAN.md D2.
public protocol Namer: Sendable {
    var id: String { get }
    func availability() -> Availability
    func suggest(for url: URL, context: PhotoContext) throws -> NameSuggestion
}

/// What `rename` intends to do with one file.
public struct Proposal: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case convert, rename, skip }
    public var source: String
    public var action: Action
    public var target: String?
    public var reason: String?
    public var template: String?
    public var tokens: [String: String]?
    public var context: PhotoContext?
    public var suggestion: NameSuggestion?
    /// Time spent planning this file (Vision and naming).
    public var timings: StageTimings?

    public static func skip(_ source: URL, _ reason: String) -> Proposal {
        Proposal(source: source.path, action: .skip, reason: reason)
    }
}
