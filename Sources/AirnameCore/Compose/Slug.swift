import Foundation

/// Filename-safe slugs: lowercase ASCII, hyphen-separated, diacritics folded.
public enum Slug {
    public static let stopWords: Set<String> = [
        "a", "an", "the", "of", "and", "or", "to", "in", "on", "at", "for", "with", "by", "from",
        "is", "are", "was", "this", "that", "it", "its", "as", "be",
    ]

    /// - Parameters:
    ///   - trimStopWords: drop stop-words (only if at least one other word remains).
    ///   - maxWords / maxChars: caps, applied at word boundaries.
    public static func make(_ input: String, trimStopWords: Bool = true, maxWords: Int = .max, maxChars: Int = .max) -> String {
        let folded = (input.applyingTransform(.toLatin, reverse: false) ?? input)
            .applyingTransform(.stripDiacritics, reverse: false) ?? input
        let lowered = folded.lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        var words = lowered
            .split(whereSeparator: { !(($0.isASCII && ($0.isLetter || $0.isNumber))) })
            .map(String.init)
        if trimStopWords {
            let kept = words.filter { !stopWords.contains($0) }
            if !kept.isEmpty { words = kept }
        }
        var out: [String] = []
        var length = 0
        for w in words.prefix(maxWords) {
            let add = w.count + (out.isEmpty ? 0 : 1)
            if length + add > maxChars {
                if out.isEmpty { out.append(String(w.prefix(maxChars))) }
                break
            }
            out.append(w)
            length += add
        }
        return out.joined(separator: "-")
    }
}
