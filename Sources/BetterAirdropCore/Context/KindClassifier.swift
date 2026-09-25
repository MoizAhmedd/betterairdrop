import Foundation

/// Decides what kind of image this is. Deterministic rules over metadata and Vision output,
/// in priority order; the first match wins and its reason is shown by `explain`.
public enum KindClassifier {
    static let receiptWords = ["total", "subtotal", "sub-total", "tax", "hst", "gst", "vat", "visa", "mastercard",
                               "debit", "amex", "change due", "amount due", "balance due", "receipt", "cash", "tip"]
    static let money = try! NSRegularExpression(pattern: #"(?<![\d.,])(?:[$€£]\s?)?\d{1,5}[.,]\d{2}(?![\d])"#)

    public static func classify(metadata m: PhotoMetadata, vision v: VisionResult?) -> (Kind, String) {
        if m.userComment?.trimmingCharacters(in: .whitespaces) == "Screenshot" { return (.screenshot, "EXIF UserComment is \"Screenshot\"") }
        if m.creatorBundleID == "com.apple.springboard" { return (.screenshot, "created by SpringBoard (iOS screenshot)") }
        guard let v else { return (.photo, "default (no Vision analysis)") }

        let lines = v.lines.filter { $0.confidence >= 0.3 }
        let text = lines.map(\.text).joined(separator: "\n").lowercased()
        let amounts = moneyCount(text)
        let hits = receiptWords.filter { text.contains($0) }
        if lines.count >= 4 && amounts >= 2 && !hits.isEmpty {
            return (.receipt, "\(amounts) amounts and \"\(hits.prefix(2).joined(separator: "\", \""))\" in the text")
        }

        func label(_ ids: String...) -> VisionResult.Label? {
            v.labels.first { ids.contains($0.id) && $0.confidence >= 0.3 }
        }
        if let l = label("whiteboard", "blackboard") {
            return (.whiteboard, "Vision label \(l.id) \(String(format: "%.2f", l.confidence))")
        }

        // Document segmentation fires on almost any rectangle (M0), so it needs plenty of text too.
        let docRect = (v.documentConfidence ?? 0) >= 0.8 && (v.documentArea ?? 0) >= 0.25
        let docLabel = label("document", "printed_page", "paper")
        if lines.count >= 8 && (docRect || (docLabel?.confidence ?? 0) >= 0.5) {
            let why = docRect ? "a page-sized document outline" : "Vision label \(docLabel!.id)"
            return (.document, "\(why) and \(lines.count) lines of text")
        }
        return (.photo, "default")
    }

    static func moneyCount(_ s: String) -> Int {
        money.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }
}
