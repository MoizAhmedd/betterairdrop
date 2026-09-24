import Foundation

/// The always-available floor: composes a subject from Vision labels and OCR, deterministically.
/// Rules come from the M0 eval (docs/spikes.md): drop Vision's parent labels, keep at most two leaf
/// labels, rank OCR lines by text size, and prefer text for screenshots, documents and whiteboards.
public struct VisionNamer: Namer {
    public let id = "vision"
    public init() {}

    public func availability() -> Availability { .ready }

    /// Labels that are either too generic to name a photo or are parents in Vision's taxonomy
    /// (returned with the same score as the more specific child: portal ⊃ window, tableware ⊃ drinking_glass).
    static let parents: Set<String> = [
        "structure", "outdoor", "indoor", "sky", "people", "adult", "child", "material", "wood_processed",
        "wood_natural", "document", "text", "screenshot", "machine", "conveyance", "land", "plant", "interior_room",
        "room", "consumer_electronics", "container", "clothing", "footwear", "art", "liquid", "water_body", "water",
        "vegetation", "grass", "tree", "cloudy", "blue_sky", "daytime", "night_sky", "textile", "furniture", "tool",
        "equipment", "decoration", "games", "portal", "tableware", "utensil", "raw_glass", "optical_equipment",
        "frozen", "domicile", "food", "frame", "illustrations", "chart", "diagram", "printed_page", "book", "sign",
        "vehicle", "animal", "mammal", "housewares", "cord", "light", "seat", "jewelry", "baked_goods", "drink",
        "sport", "paper", "arts_and_crafts", "office_supplies", "shelter", "urban", "road", "street", "cityscape",
    ]

    static let statusNoise = try! NSRegularExpression(pattern: #"^[\d:.\s%()+•?|/<>=-]*$|^\d{1,2}:\d{2}"#)
    static let amount = try! NSRegularExpression(pattern: #"(?:[$€£]\s?)?(\d{1,5})[.,](\d{2})(?!\d)"#)

    public func suggest(for url: URL, context ctx: PhotoContext) throws -> NameSuggestion {
        var why: [String] = []
        let v = ctx.vision ?? VisionResult()
        let kind = ctx.kind
        let leaves = v.labels.filter { $0.confidence >= 0.3 && !Self.parents.contains($0.id) }.prefix(2)
        let strongLabel = leaves.contains { $0.confidence >= 0.5 }

        if kind == .receipt {
            let merchant = Self.merchant(v.lines)
            let total = Self.total(v.lines)
            why.append("receipt: merchant from the top of the receipt, total from the line that says total")
            return NameSuggestion(kind: kind, subject: merchant ?? "receipt", merchant: merchant, total: total,
                                  confidence: merchant == nil && total == nil ? 0.2 : 0.7, backend: id, why: why)
        }

        let textFirst = kind != .photo
        let photoNeedsText = kind == .photo && !strongLabel && v.lines.count >= 3
        if textFirst || photoNeedsText {
            // Photos only fall back to text we're sure of (OCR misreads make bad names).
            let minConfidence = kind == .photo ? 0.8 : 0.5
            if let line = Self.salientLine(v.lines, minConfidence: minConfidence, skipStatusBar: kind == .screenshot) {
                why.append("subject from the most prominent text line (\(textFirst ? "\(kind.rawValue)s are named by their text" : "no strong label"))")
                return NameSuggestion(kind: kind, subject: line.text, confidence: min(0.9, line.confidence), backend: id, why: why)
            }
        }
        if !leaves.isEmpty {
            let subject = leaves.map { $0.id.replacingOccurrences(of: "_", with: " ") }.joined(separator: " ")
            why.append("subject from Vision labels " + leaves.map { "\($0.id) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", "))
            return NameSuggestion(kind: kind, subject: subject, confidence: leaves.first!.confidence, backend: id, why: why)
        }
        why.append("no label ≥ 0.30 and no usable text, so the name falls back to the original number")
        return NameSuggestion(kind: kind, subject: "", confidence: 0, backend: id, why: why)
    }

    /// The tallest confident line with at least 4 letters that isn't clock/battery noise.
    static func salientLine(_ lines: [VisionResult.TextLine], minConfidence: Double, skipStatusBar: Bool) -> VisionResult.TextLine? {
        lines.filter { l in
            guard l.confidence >= minConfidence, l.text.filter(\.isLetter).count >= 4 else { return false }
            if skipStatusBar && l.top < 0.05 { return false }
            let s = l.text
            return statusNoise.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil
        }.max { score($0) < score($1) }
    }

    static func score(_ l: VisionResult.TextLine) -> Double {
        l.height * Double(min(l.text.filter(\.isLetter).count, 20)).squareRoot()
    }

    /// The merchant is usually the biggest text in the top third of a receipt.
    static func merchant(_ lines: [VisionResult.TextLine]) -> String? {
        let top = lines.filter { $0.top <= 0.35 }
        return salientLine(top.isEmpty ? lines : top, minConfidence: 0.5, skipStatusBar: false)?.text
    }

    /// The amount on a "total" line (not subtotal), else the largest amount. `84.12` → `84-12`.
    static func total(_ lines: [VisionResult.TextLine]) -> String? {
        func amounts(_ s: String) -> [(Double, String)] {
            amount.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
                guard let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s),
                      let v = Double("\(s[a]).\(s[b])") else { return nil }
                return (v, "\(s[a])-\(s[b])")
            }
        }
        let totalLines = lines.enumerated().filter { _, l in
            let t = l.text.lowercased()
            return t.contains("total") && !t.contains("subtotal") && !t.contains("sub-total") && !t.contains("before")
        }
        for (i, l) in totalLines {
            // The amount is often OCR'd as a separate line; look at this line, then the next one.
            if let a = amounts(l.text).max(by: { $0.0 < $1.0 }) { return a.1 }
            if i + 1 < lines.count, let a = amounts(lines[i + 1].text).first { return a.1 }
        }
        return lines.flatMap { amounts($0.text) }.max { $0.0 < $1.0 }?.1
    }
}
