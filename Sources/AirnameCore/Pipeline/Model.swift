import Foundation

public enum Kind: String, Codable, Sendable, CaseIterable {
    case photo, screenshot, receipt, document, whiteboard
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

    public init(file: String, metadata: PhotoMetadata, place: Place? = nil, airdrop: Bool = false,
                vision: VisionResult? = nil, kind: Kind = .photo, kindReason: String = "default") {
        self.file = file; self.metadata = metadata; self.place = place; self.airdrop = airdrop
        self.vision = vision; self.kind = kind; self.kindReason = kindReason
    }
}

/// What a namer backend returns. Only the subject (and receipt fields) come from the model;
/// date, place and kind are decided locally.
public struct NameSuggestion: Codable, Sendable, Equatable {
    public var kind: Kind
    public var subject: String
    public var merchant: String?
    public var total: String?
    public var confidence: Double
    public var backend: String
    /// Short human-readable trail for `explain`.
    public var why: [String]
    /// Tokens a cloud backend used for this photo (nil for on-device backends).
    public var usage: TokenUsage?
    /// Set when the chosen backend failed and another one produced this name: why the first failed.
    public var fallbackFrom: String?

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

    public static func skip(_ source: URL, _ reason: String) -> Proposal {
        Proposal(source: source.path, action: .skip, reason: reason)
    }
}
