import Foundation

/// Claude (Haiku 4.5 by default) over the Messages API, with raw HTTP (there's no official Swift SDK).
///
/// What leaves the Mac: a 1024 px JPEG re-encoded with no metadata (`UploadImage`), and a short
/// text context (date, city name, kind hints, a truncated OCR snippet, device/creator hints).
/// Never GPS coordinates, never the file name. See `ClaudePrompt`.
public struct ClaudeNamer: Namer {
    public let id = "claude"
    public static let defaultModel = "claude-haiku-4-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public var model: String
    public var auth: ClaudeAuth
    public var transport: any HTTPTransport
    public var timeout: TimeInterval = 20
    public var maxAttempts = 3
    public var maxTokens = 256
    /// Injected in tests so retries don't really sleep.
    public var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    public init(model: String = ClaudeNamer.defaultModel, auth: ClaudeAuth = .shared, transport: any HTTPTransport = URLSessionTransport()) {
        self.model = model; self.auth = auth; self.transport = transport
    }

    public func availability() -> Availability {
        auth.resolve() == nil
            ? .unavailable("no Anthropic credential: set ANTHROPIC_API_KEY, run `betterairdrop auth claude`, or `betterairdrop auth login`")
            : .ready
    }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case noCredential
        case http(Int, String)
        case refusal
        case truncated
        case badOutput(String)
        case network(String)

        public var description: String {
            switch self {
            case .noCredential: "no Anthropic credential"
            case .http(let code, let msg): "Anthropic API returned \(code): \(msg)"
            case .refusal: "Claude declined to describe this image"
            case .truncated: "Claude's answer was cut off (max_tokens)"
            case .badOutput(let why): "Claude's answer wasn't usable: \(why)"
            case .network(let why): "network error: \(why)"
            }
        }
    }

    /// Remembers, for this process, that the model rejected `output_config` (so we stop sending it).
    static let structuredOutput = Flag(true)

    public func suggest(for url: URL, context ctx: PhotoContext) throws -> NameSuggestion {
        var timings = StageTimings()
        let image = try timings.time(.encode) { try UploadImage.jpeg(from: url) }
        let prompt = ClaudePrompt.context(ctx)
        var usage = TokenUsage(model: model, inputTokens: 0, outputTokens: 0)
        var why = ["sent a \(image.count / 1024) KB metadata-free JPEG and the text context to \(model)"]

        let text: String
        do {
            text = try call(image: image, prompt: prompt, structured: Self.structuredOutput.value, usage: &usage, timings: &timings)
        } catch Error.http(400, let msg) where Self.structuredOutput.value && ClaudePrompt.looksLikeOutputConfigRejection(msg) {
            // Structured outputs not accepted for this model: ask for JSON in the prompt and validate strictly.
            Self.structuredOutput.value = false
            why.append("the API rejected output_config, so JSON was requested in the prompt instead")
            text = try call(image: image, prompt: prompt, structured: false, usage: &usage, timings: &timings)
        }
        let answer = try ClaudePrompt.parse(text)
        var s = answer.suggestion(context: ctx, backend: id, maxWords: 6)
        s.usage = usage
        s.timings = timings
        s.why = why + s.why
        return s
    }

    /// One logical request, with retries for 429/5xx/network errors. Returns the first text block.
    func call(image: Data, prompt: String, structured: Bool, usage: inout TokenUsage, timings: inout StageTimings) throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ClaudePrompt.body(model: model, maxTokens: maxTokens, image: image,
                                                                                  context: prompt, structured: structured))
        var refreshedAuth = false
        var attempt = 0
        while true {
            attempt += 1
            guard let cred = timings.time(.credential, { auth.resolve() }) else { throw Error.noCredential }
            var req = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
            req.httpMethod = "POST"
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            for (k, v) in cred.headers { req.setValue(v, forHTTPHeaderField: k) }
            req.httpBody = body

            let response: HTTPURLResponse, data: Data
            do {
                (response, data) = try timings.time(.claude) { try transport.send(req) }
            } catch {
                if attempt < maxAttempts { timings.time(.claude) { sleep(backoff(attempt, retryAfter: nil)) }; continue }
                throw Error.network((error as NSError).localizedDescription)
            }
            let status = response.statusCode
            if status == 200 {
                return try Self.readMessage(data, usage: &usage)
            }
            let message = Self.errorMessage(data)
            if status == 401, case .oauth = cred, !refreshedAuth {
                // The CLI's access token may have expired mid-run: fetch a fresh one once.
                refreshedAuth = true
                auth.invalidate()
                continue
            }
            if (status == 429 || status == 529 || status >= 500) && attempt < maxAttempts {
                let wait = backoff(attempt, retryAfter: response.value(forHTTPHeaderField: "retry-after"))
                timings.time(.claude) { sleep(wait) }
                continue
            }
            throw Error.http(status, message)
        }
    }

    /// `retry-after` (seconds) if the server sent one, else 1 s, 2 s, 4 s… with a little jitter. Capped at 20 s.
    func backoff(_ attempt: Int, retryAfter: String?) -> TimeInterval {
        if let r = retryAfter.flatMap(Double.init), r >= 0 { return min(r, 20) }
        return min(pow(2, Double(attempt - 1)) + Double.random(in: 0...0.25), 20)
    }

    /// Checks `stop_reason` first, adds usage, returns the first text block.
    static func readMessage(_ data: Data, usage: inout TokenUsage) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.badOutput("response isn't JSON")
        }
        if let u = obj["usage"] as? [String: Any] {
            usage.inputTokens += (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                + (u["cache_creation_input_tokens"] as? Int ?? 0)
            usage.outputTokens += u["output_tokens"] as? Int ?? 0
        }
        switch obj["stop_reason"] as? String {
        case "refusal": throw Error.refusal
        case "max_tokens": throw Error.truncated
        default: break
        }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw Error.badOutput("no text block")
        }
        return text
    }

    static func errorMessage(_ data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = obj["error"] as? [String: Any], let m = e["message"] as? String {
            return m
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Bool
        init(_ v: Bool) { self.v = v }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }
}

// MARK: - Prompt, request body and answer parsing

public enum ClaudePrompt {
    static let kinds = ["photo", "screenshot", "receipt", "document", "whiteboard", "other"]

    static let instructions = """
    You name image files. Look at the image and the context, then describe the image's main subject \
    as a short filename phrase.

    Rules for "subject":
    - 2 to 6 lowercase words, plain English, specific and concrete: "walnut lamp on oak sideboard", \
    "red bicycle against brick wall", "bowl of soup on wooden table", "weekly weather forecast".
    - Name the scene or the thing, not a generic category. Avoid bare words like "photo", "image", \
    "object", "room" or "text".
    - For screenshots and documents, describe what's on the screen or page (the app, page title or topic).
    - Never include people's names, usernames, handles, emails, phone numbers, addresses or account \
    numbers, even if they are visible. Describe people generically ("person reading on bench").
    - Don't repeat the date or the city from the context; they are added to the filename separately.
    - Don't start with "photo of", "picture of", "screenshot of" or "image of".

    Other fields:
    - "kind": photo, screenshot, receipt, document, whiteboard or other. Trust the context's creator hint \
    for screenshots.
    - "merchant": for a receipt, the store name (1-3 words); otherwise "".
    - "total": for a receipt, the total paid as digits like "84.12"; otherwise "".
    - "confidence": 0 to 1, how sure you are that the subject describes the image well.
    - "people_present": true if a person is visible.
    """

    static let jsonInstructions = """

    Reply with only a JSON object, no prose and no code fences, exactly with these keys: \
    {"subject": string, "kind": string, "merchant": string, "total": string, "confidence": number, "people_present": boolean}
    """

    /// The JSON schema for `output_config.format`. Every property is required; no extras allowed.
    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "subject": ["type": "string"],
                "kind": ["type": "string", "enum": kinds],
                "merchant": ["type": "string"],
                "total": ["type": "string"],
                "confidence": ["type": "number"],
                "people_present": ["type": "boolean"],
            ],
            "required": ["subject", "kind", "merchant", "total", "confidence", "people_present"],
            "additionalProperties": false,
        ]
    }

    /// The Messages API body. The image block comes before the text block; no `thinking`.
    static func body(model: String, maxTokens: Int, image: Data, context: String, structured: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": instructions + (structured ? "" : jsonInstructions),
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]],
                    ["type": "text", "text": context],
                ],
            ]],
        ]
        if structured {
            b["output_config"] = ["format": ["type": "json_schema", "schema": schema]]
        }
        return b
    }

    static func looksLikeOutputConfigRejection(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("output_config") || m.contains("json_schema") || m.contains("output format") || m.contains("structured output")
    }

    static let creatorHints: [String: String] = [
        "com.apple.springboard": "SpringBoard, i.e. an iOS screenshot",
        "com.apple.camera": "the iPhone Camera app, i.e. a camera photo",
        "com.burbn.instagram": "Instagram",
        "net.whatsapp.WhatsApp": "WhatsApp (saved image)",
    ]

    /// The text context. Only what helps naming, and never coordinates or the file name.
    public static func context(_ ctx: PhotoContext, ocrLimit: Int = 300) -> String {
        let m = ctx.metadata
        var lines = ["Context worked out on the user's Mac:"]
        if let d = m.date {
            var when = d
            if let t = m.time, t.count == 4 { when += " \(t.prefix(2)):\(t.suffix(2))" }
            lines.append("- captured: \(when)\(m.dateSource == "file" ? " (file date; no camera date)" : "")")
        }
        if let p = ctx.place { lines.append("- place: \(p.city), \(p.countryCode) (city only)") }
        if let model = m.model { lines.append("- device: \(model)") }
        if let c = m.creatorBundleID { lines.append("- created by: \(creatorHints[c] ?? c)") }
        if m.userComment?.trimmingCharacters(in: .whitespaces) == "Screenshot" { lines.append("- EXIF says: Screenshot") }
        lines.append("- local kind guess: \(ctx.kind.rawValue) (\(ctx.kindReason))")
        if let v = ctx.vision {
            let labels = v.labels.filter { $0.confidence >= 0.3 }.prefix(6).map { "\($0.id) \(String(format: "%.2f", $0.confidence))" }
            if !labels.isEmpty { lines.append("- on-device labels: \(labels.joined(separator: ", "))") }
            let text = ocrSnippet(v, limit: ocrLimit)
            if !text.isEmpty { lines.append("- text found in the image (OCR, truncated): \"\(text)\"") }
        }
        return lines.joined(separator: "\n")
    }

    /// Confident OCR lines, biggest text first, joined and cut to `limit` characters.
    static func ocrSnippet(_ v: VisionResult, limit: Int) -> String {
        let lines = v.lines.filter { $0.confidence >= 0.5 && $0.text.contains(where: \.isLetter) }
            .sorted { $0.height > $1.height }
            .map { $0.text.replacingOccurrences(of: "\"", with: "'") }
        var out = ""
        for l in lines {
            let add = out.isEmpty ? l : " / " + l
            if out.count + add.count > limit {
                if out.isEmpty { out = String(l.prefix(limit)) }
                break
            }
            out += add
        }
        return out
    }

    public struct Answer: Codable, Sendable, Equatable {
        public var subject: String
        public var kind: String
        public var merchant: String?
        public var total: String?
        public var confidence: Double
        public var people_present: Bool?

        /// Merges with the local context. A screenshot identified by metadata stays a screenshot;
        /// otherwise Claude's kind wins (it sees the pixels; the local rules are heuristics).
        func suggestion(context ctx: PhotoContext, backend: String, maxWords: Int) -> NameSuggestion {
            var why: [String] = []
            let theirs = Kind(rawValue: kind) ?? .photo
            let finalKind: Kind = ctx.metadata.isScreenshotByMetadata ? .screenshot : theirs
            if finalKind != theirs { why.append("kind: kept screenshot from the metadata (Claude said \(kind))") }
            else if finalKind != ctx.kind { why.append("kind: Claude says \(kind) (local rules said \(ctx.kind.rawValue))") }
            let subj = ClaudePrompt.cleanSubject(subject, city: ctx.place?.city, maxWords: maxWords)
            why.append("subject \"\(subj)\" from Claude (confidence \(String(format: "%.2f", confidence))\(people_present == true ? ", people present" : ""))")
            let m = merchant?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            let t = total?.trimmingCharacters(in: .whitespaces).nilIfEmpty.map { $0.replacingOccurrences(of: ".", with: "-") }
            return NameSuggestion(kind: finalKind, subject: subj, merchant: finalKind == .receipt ? m : nil,
                                  total: finalKind == .receipt ? t : nil,
                                  confidence: min(max(confidence, 0), 1), backend: backend, why: why)
        }
    }

    /// Strict parsing: the whole text (or, in prompt-JSON mode, the first `{…}` object) must decode,
    /// the kind must be known, and the subject must be non-empty.
    public static func parse(_ text: String) throws -> Answer {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !json.hasPrefix("{"), let a = json.firstIndex(of: "{"), let b = json.lastIndex(of: "}"), a < b {
            json = String(json[a...b])
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(json.utf8)) else {
            throw ClaudeNamer.Error.badOutput("not the expected JSON object")
        }
        guard kinds.contains(answer.kind) else { throw ClaudeNamer.Error.badOutput("unknown kind \(answer.kind)") }
        guard Slug.make(answer.subject, trimStopWords: false).count >= 2 else { throw ClaudeNamer.Error.badOutput("empty subject") }
        guard answer.confidence.isFinite else { throw ClaudeNamer.Error.badOutput("confidence isn't a number") }
        return answer
    }

    static let leadIns = ["a photo of ", "photo of ", "a picture of ", "picture of ", "an image of ", "image of ",
                          "a screenshot of ", "screenshot of ", "screenshot ", "photo "]

    /// Lowercases, drops a "photo of" lead-in and a repeated city name, and caps the word count.
    static func cleanSubject(_ s: String, city: String?, maxWords: Int) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for p in leadIns where t.hasPrefix(p) && t.count > p.count + 2 { t = String(t.dropFirst(p.count)); break }
        if let city {
            let c = Slug.make(city, trimStopWords: false).replacingOccurrences(of: "-", with: " ")
            let words = t.split(separator: " ").map(String.init)
            let cityWords = c.split(separator: " ").map(String.init)
            if !cityWords.isEmpty, words.count - cityWords.count >= 2 {
                var out: [String] = [], i = 0
                while i < words.count {
                    if Array(words[i..<min(i + cityWords.count, words.count)]) == cityWords { i += cityWords.count; continue }
                    out.append(words[i]); i += 1
                }
                t = out.joined(separator: " ")
            }
        }
        return t.split(separator: " ").prefix(maxWords).joined(separator: " ")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - HTTP

/// Sends one request and returns the response. Swappable so tests never touch the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) throws -> (HTTPURLResponse, Data)
}

/// `URLSession`, used synchronously (the namer API is synchronous).
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        final class Box: @unchecked Sendable { var result: Result<(HTTPURLResponse, Data), any Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            if let error { box.result = .failure(error) }
            else if let http = response as? HTTPURLResponse { box.result = .success((http, data ?? Data())) }
            else { box.result = .failure(URLError(.badServerResponse)) }
            done.signal()
        }.resume()
        done.wait()
        return try box.result!.get()
    }
}

// MARK: - Fallback

/// Tries `primary`; on any error, names the photo with `fallback` and records why.
/// This is how a network or API problem never fails a rename.
public struct FallbackNamer: Namer {
    public let primary: any Namer
    public let fallback: any Namer
    public var id: String { primary.id }

    public init(primary: any Namer, fallback: any Namer) { self.primary = primary; self.fallback = fallback }

    public func availability() -> Availability {
        if case .ready = primary.availability() { return .ready }
        return fallback.availability()
    }

    public func suggest(for url: URL, context: PhotoContext) throws -> NameSuggestion {
        let firstError: any Error
        if case .ready = primary.availability() {
            do { return try primary.suggest(for: url, context: context) } catch { firstError = error }
        } else {
            firstError = BackendError.unavailable(primary.id, reason: "not available")
        }
        var s = try fallback.suggest(for: url, context: context)
        s.fallbackFrom = "\(primary.id): \(firstError)"
        s.why.insert("\(primary.id) failed (\(firstError)), so \(fallback.id) named it", at: 0)
        return s
    }
}
