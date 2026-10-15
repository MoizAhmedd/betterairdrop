import Foundation

/// The prompt, request text and answer for naming a PDF from its text (Pro, "Name PDFs too").
/// Shared by Claude with the user's key, hosted naming (`POST /v1/name-text`, whose Worker pins a copy
/// in `hosted/src/prompt-text.json`) and Apple Intelligence. No image is ever sent.
public enum DocumentPrompt {
    public static let kinds = Kind.pdfKinds.map(\.rawValue)

    static let instructions = """
    You name PDF files. You get text extracted from the first pages of a PDF on the user's Mac. Work \
    out what the document is and describe it as a short filename phrase.

    Rules for "subject":
    - 2 to 6 lowercase words, plain English, specific: "internet and tv bill", "lease agreement 45 \
    carlton st", "notice of assessment 2025", "dishwasher installation manual", "attention is all you need".
    - Name the document, not the format. Avoid bare words like "document", "pdf", "file", "scan" or "page".
    - For a paper, book or manual, use its title, shortened. For a contract, its type and what it \
    covers (a property address is fine).
    - Never include people's names, emails, phone numbers, or account, policy, card or invoice numbers, \
    even if they appear in the text.
    - Don't repeat the date, the amount or the kind; they are added to the filename separately.

    Other fields:
    - "kind": invoice, receipt, statement, contract, form, letter, ticket, manual, paper or other. An \
    invoice or bill asks for payment; a receipt confirms one; a statement lists account activity.
    - "issuer": the company or organisation that issued it, 1 to 3 words ("Bell Canada", "TD Bank"); \
    "" if there is none or it's a private person.
    - "amount": for an invoice or receipt, the total due or paid as digits like "84.12"; otherwise "".
    - "date": the document's own date as YYYY-MM-DD: the invoice or receipt date, a statement's \
    closing date, the date a contract was signed, a letter's date, a ticket's travel or event date, a \
    paper's publication date. Not a due date. "" if the text has none.
    - "confidence": 0 to 1, how sure you are that the subject describes the document well.
    """

    static let jsonInstructions = """

    Reply with only a JSON object, no prose and no code fences, exactly with these keys: \
    {"subject": string, "kind": string, "issuer": string, "amount": string, "date": string, "confidence": number}
    """

    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "subject": ["type": "string"],
                "kind": ["type": "string", "enum": kinds],
                "issuer": ["type": "string"],
                "amount": ["type": "string"],
                "date": ["type": "string"],
                "confidence": ["type": "number"],
            ],
            "required": ["subject", "kind", "issuer", "amount", "date", "confidence"],
            "additionalProperties": false,
        ]
    }

    /// First line of the context; the Worker refuses anything else.
    public static let contextPrefix = "PDF worked out on the user's Mac:"

    /// Short facts about the PDF (never its file name or path). The text goes separately.
    public static func context(_ doc: DocumentText) -> String {
        var lines = [contextPrefix, "- pages: \(doc.pages)"]
        lines.append(doc.source == .ocr
            ? "- text from: on-device OCR of page 1 (a scan; expect misread characters)"
            : "- text from: the PDF's text layer, first \(min(doc.pages, PDFText.maxPages)) page\(min(doc.pages, PDFText.maxPages) == 1 ? "" : "s")")
        if let t = doc.title {
            lines.append("- title in the PDF's metadata: \(t.replacingOccurrences(of: "\n", with: " "))")
        }
        return lines.joined(separator: "\n")
    }

    /// The one user message: the context, then the text. Built the same way by the Worker
    /// (`textMessage` in hosted/src/name.ts).
    public static func message(context: String, text: String) -> String {
        context + "\n\nText from the PDF (truncated):\n<<<\n" + text + "\n>>>"
    }

    /// The Messages API body: system prompt and one text block. No image, no `thinking`.
    static func body(model: String, maxTokens: Int, context: String, text: String, structured: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": instructions + (structured ? "" : jsonInstructions),
            "messages": [["role": "user", "content": [["type": "text", "text": message(context: context, text: text)]]]],
        ]
        if structured { b["output_config"] = ["format": ["type": "json_schema", "schema": schema]] }
        return b
    }

    public struct Answer: Codable, Sendable, Equatable {
        public var subject: String
        public var kind: String
        public var issuer: String?
        public var amount: String?
        public var date: String?
        public var confidence: Double

        public init(subject: String, kind: String, issuer: String? = nil, amount: String? = nil, date: String? = nil, confidence: Double) {
            self.subject = subject; self.kind = kind; self.issuer = issuer; self.amount = amount; self.date = date; self.confidence = confidence
        }

        /// The issuer goes in `{merchant}` for invoices, receipts and statements; the amount in
        /// `{total}` for invoices and receipts; a date that reads as a real day becomes `documentDate`.
        func suggestion(backend: String, maxWords: Int, source: String, now: Date = Date()) -> NameSuggestion {
            let k = Kind(rawValue: kind).flatMap { Kind.pdfKinds.contains($0) ? $0 : nil } ?? .other
            var why = ["kind: \(source) says \(k.rawValue)"]
            let subj = ClaudePrompt.cleanSubject(subject, city: nil, maxWords: maxWords)
            why.append("subject \"\(subj)\" from \(source) (confidence \(String(format: "%.2f", confidence)))")
            let issuer = issuer?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            let amount = amount?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                .flatMap { $0.range(of: #"^[0-9]{1,9}([.,][0-9]{1,2})?$"#, options: .regularExpression) != nil ? $0 : nil }
                .map { $0.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: ",", with: "-") }
            var s = NameSuggestion(kind: k, subject: subj,
                                   merchant: [.invoice, .receipt, .statement].contains(k) ? issuer : nil,
                                   total: [.invoice, .receipt].contains(k) ? amount : nil,
                                   confidence: min(max(confidence, 0), 1), backend: backend, why: why)
            if let d = DocumentPrompt.day(date, now: now) {
                s.documentDate = d
                s.why.append("date \(d) from the document")
            }
            return s
        }
    }

    /// `YYYY-MM-DD` that is a real calendar day between 1900 and two years from now, else nil.
    static func day(_ s: String?, now: Date = Date()) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard let d = f.date(from: s), f.string(from: d) == s, s >= "1900-01-01",
              d <= now.addingTimeInterval(2 * 366 * 86_400) else { return nil }
        return s
    }

    /// Strict, like `ClaudePrompt.parse`: the whole text or its first `{…}` must decode, the kind must
    /// be a PDF kind, the subject non-empty.
    public static func parse(_ text: String) throws -> Answer {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !json.hasPrefix("{"), let a = json.firstIndex(of: "{"), let b = json.lastIndex(of: "}"), a < b {
            json = String(json[a...b])
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(json.utf8)) else {
            throw ClaudeNamer.Error.badOutput("not the expected JSON object")
        }
        if let why = problem(with: answer) { throw ClaudeNamer.Error.badOutput(why) }
        return answer
    }

    static func problem(with a: Answer) -> String? {
        if !kinds.contains(a.kind) { return "unknown kind \(a.kind)" }
        if Slug.make(a.subject, trimStopWords: false).count < 2 { return "empty subject" }
        if !a.confidence.isFinite { return "confidence isn't a number" }
        return nil
    }
}
