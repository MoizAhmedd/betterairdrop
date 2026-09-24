import Foundation

/// Filename templates such as `{date}_{place}_{subject}`.
///
/// Tokens: date, time, place, country, subject, kind, device, merchant, total, orig.
/// Empty tokens collapse together with their separators, so `{date}_{place}_{subject}` without a
/// place renders `2026-09-21_walnut-lamp`.
public struct Template: Sendable, Equatable {
    public static let tokens: Set<String> = ["date", "time", "place", "country", "subject", "kind", "device", "merchant", "total", "orig"]
    /// Tokens that describe the photo. A name with none of them filled is refused.
    static let descriptive: Set<String> = ["subject", "merchant", "total", "orig"]
    public static let fallback = Template(unchecked: "{date}_{place}_{orig}")
    public static let maxLength = 100

    public let source: String
    enum Piece: Equatable { case literal(String), token(String) }
    let pieces: [Piece]

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case unknownToken(String), unclosedBrace, noDescriptiveToken
        public var description: String {
            switch self {
            case .unknownToken(let t): "unknown template token {\(t)}; known: \(Template.tokens.sorted().joined(separator: ", "))"
            case .unclosedBrace: "template has an unclosed {"
            case .noDescriptiveToken: "template needs at least one of {subject}, {merchant}, {total} or {orig}"
            }
        }
    }

    public init(_ source: String) throws {
        let pieces = try Self.parse(source)
        let used = Set(pieces.compactMap { if case .token(let t) = $0 { t } else { nil } })
        if let bad = used.subtracting(Self.tokens).sorted().first { throw Error.unknownToken(bad) }
        if used.isDisjoint(with: Self.descriptive) { throw Error.noDescriptiveToken }
        self.source = source
        self.pieces = pieces
    }

    init(unchecked source: String) {
        self.source = source
        self.pieces = (try? Self.parse(source)) ?? []
    }

    static func parse(_ s: String) throws -> [Piece] {
        var out: [Piece] = []
        var lit = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "{" {
                guard let close = s[i...].firstIndex(of: "}") else { throw Error.unclosedBrace }
                if !lit.isEmpty { out.append(.literal(lit)); lit = "" }
                out.append(.token(String(s[s.index(after: i)..<close])))
                i = s.index(after: close)
            } else {
                lit.append(s[i]); i = s.index(after: i)
            }
        }
        if !lit.isEmpty { out.append(.literal(lit)) }
        return out
    }

    /// Renders the stem (no extension). Returns nil when no descriptive token has a value,
    /// so the caller can fall back to `Template.fallback`.
    public func render(_ values: [String: String]) -> String? {
        let filled = pieces.contains { if case .token(let t) = $0 { Self.descriptive.contains(t) && !(values[t] ?? "").isEmpty } else { false } }
        guard filled else { return nil }
        var raw = ""
        for p in pieces {
            switch p {
            case .literal(let l): raw += Self.sanitizeLiteral(l)
            case .token(let t): raw += values[t] ?? ""
            }
        }
        return Self.normalize(raw)
    }

    /// Collapses separator runs left behind by empty tokens and trims them from the ends.
    static func normalize(_ s: String) -> String {
        let seps: Set<Character> = ["_", "-", " ", "."]
        var out = ""
        var run = ""
        for c in s {
            if seps.contains(c) { run.append(c); continue }
            if !run.isEmpty {
                if !out.isEmpty { out.append(run.contains("_") ? "_" : run.first!) }
                run = ""
            }
            out.append(c)
        }
        if out.count > maxLength {
            var cut = String(out.prefix(maxLength))
            if let last = cut.lastIndex(where: { seps.contains($0) }), cut.distance(from: cut.startIndex, to: last) > 10 {
                cut = String(cut[..<last])
            }
            out = cut
        }
        return out
    }

    /// Literals may not introduce path separators, leading dots or control characters.
    static func sanitizeLiteral(_ s: String) -> String {
        String(s.map { c -> Character in
            if c == "/" || c == ":" || c.isNewline || (c.asciiValue.map { $0 < 0x20 } ?? false) { return "-" }
            return c
        })
    }
}
