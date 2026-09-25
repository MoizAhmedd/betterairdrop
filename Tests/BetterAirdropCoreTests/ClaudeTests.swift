@testable import BetterAirdropCore
import Foundation
import ImageIO
import Testing

/// Canned HTTP for the Claude backend. No request ever reaches the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String; var headers: [String: String] = [:]; var fail: URLError.Code? = nil }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []
    static let lock = NSLock()

    static func reset(_ r: [Reply]) { lock.lock(); replies = r; requests = []; lock.unlock() }
    static var captured: [(URLRequest, Data)] { lock.lock(); defer { lock.unlock() }; return requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        Self.lock.lock()
        Self.requests.append((request, body))
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: "{}") : Self.replies.removeFirst()
        Self.lock.unlock()
        if let code = reply.fail { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var transport: URLSessionTransport {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSessionTransport(configuration: c)
    }
}

func message(_ answer: String, stop: String = "end_turn", input: Int = 1500, output: Int = 40) -> String {
    let escaped = String(data: try! JSONSerialization.data(withJSONObject: [answer], options: [.fragmentsAllowed]), encoding: .utf8)!
    return """
    {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5","stop_reason":"\(stop)",
     "content":[{"type":"text","text":\(escaped.dropFirst().dropLast())}],
     "usage":{"input_tokens":\(input),"output_tokens":\(output)}}
    """
}

let goodAnswer = #"{"subject":"Walnut lamp on oak sideboard","kind":"photo","merchant":"","total":"","confidence":0.92,"people_present":false}"#

@Suite(.serialized) struct ClaudeNamerTests {
    let dir = TestImages.TempDir()

    func namer(_ auth: ClaudeAuth = ClaudeAuth(environment: ["ANTHROPIC_API_KEY": "sk-ant-test-key"], keychain: { nil }, antPath: { nil }),
               sleeps: SleepLog = SleepLog()) -> ClaudeNamer {
        ClaudeNamer.structuredOutput.value = true
        var n = ClaudeNamer(auth: auth, transport: StubURLProtocol.transport)
        n.sleep = { sleeps.append($0) }
        return n
    }

    final class SleepLog: @unchecked Sendable {
        var delays: [TimeInterval] = []
        func append(_ d: TimeInterval) { delays.append(d) }
    }

    func photo(_ meta: TestImages.Meta = .init()) -> (URL, PhotoContext) {
        let url = TestImages.write(dir.path("IMG_\(UUID().uuidString.prefix(4)).HEIC"), type: .heic, meta: meta, width: 2400, height: 1600)
        var m = try! PhotoMetadata.read(url)
        m.creatorBundleID = "com.apple.camera"
        let ctx = PhotoContext(file: url.path, metadata: m, place: Place(city: "Toronto", countryCode: "CA", distanceKm: 3),
                               vision: VisionResult(labels: [.init("lamp", 0.7)], lines: [.init("IKEA", confidence: 0.9, height: 0.05)]),
                               kind: .photo, kindReason: "default")
        return (url, ctx)
    }

    func body(_ i: Int = 0) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: StubURLProtocol.captured[i].1) as? [String: Any])
    }

    @Test func requestShapeAndResult() throws {
        StubURLProtocol.reset([.init(status: 200, body: message(goodAnswer))])
        let (url, ctx) = photo()
        let s = try namer().suggest(for: url, context: ctx)
        #expect(s.subject == "walnut lamp on oak sideboard")
        #expect(s.kind == .photo && s.backend == "claude" && s.confidence == 0.92)
        #expect(s.usage == TokenUsage(model: "claude-haiku-4-5", inputTokens: 1500, outputTokens: 40))

        let (req, _) = StubURLProtocol.captured[0]
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-key")
        #expect(req.value(forHTTPHeaderField: "authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(req.timeoutInterval == 20)

        let b = try body()
        #expect(b["model"] as? String == "claude-haiku-4-5")
        #expect(b["max_tokens"] as? Int == 256)
        #expect(b["thinking"] == nil)
        let content = try #require(((b["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? [String: String])
        #expect(source["type"] == "base64" && source["media_type"] == "image/jpeg")
        let b64 = try #require(source["data"])
        #expect(!b64.contains("\n") && !b64.contains("\r"))

        // The uploaded image: ≤ 1024 px, JPEG, and no EXIF date, GPS or camera make/model.
        let jpeg = try #require(Data(base64Encoded: b64))
        let src = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(src) as String? == "public.jpeg")
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0) == 1024)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect(props[kCGImagePropertyTIFFDictionary] == nil)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil && exif[kCGImagePropertyExifUserComment] == nil)

        // Context is sent as text, without coordinates or the file name.
        let text = try #require(content[1]["text"] as? String)
        #expect(text.contains("2026-09-21 14:03") && text.contains("Toronto, CA") && text.contains("iPhone Camera app"))
        #expect(text.contains("lamp 0.70") && text.contains("\"IKEA\""))
        #expect(!text.contains("43.6") && !text.contains("79.3") && !text.contains("IMG_"))

        let format = try #require((b["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(schema["required"] as? [String] ?? []) == ["subject", "kind", "merchant", "total", "confidence", "people_present"])
        #expect(((schema["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
                == ["photo", "screenshot", "receipt", "document", "whiteboard", "other"])
    }

    @Test func oauthSendsBearerAndBetaHeaderOnly() throws {
        StubURLProtocol.reset([.init(status: 200, body: message(goodAnswer))])
        let auth = ClaudeAuth(environment: [:], keychain: { nil }, antPath: { "/fake/ant" }, runAnt: { _, _ in "tok-123\n" })
        let (url, ctx) = photo()
        _ = try namer(auth).suggest(for: url, context: ctx)
        let req = StubURLProtocol.captured[0].0
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer tok-123")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func expiredOAuthTokenIsRefreshedOnce() throws {
        StubURLProtocol.reset([.init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"expired"}}"#),
                               .init(status: 200, body: message(goodAnswer))])
        final class Counter: @unchecked Sendable { var n = 0 }
        let c = Counter()
        let auth = ClaudeAuth(environment: [:], keychain: { nil }, antPath: { "/fake/ant" }, runAnt: { _, _ in c.n += 1; return "tok-\(c.n)" })
        let (url, ctx) = photo()
        _ = try namer(auth).suggest(for: url, context: ctx)
        #expect(StubURLProtocol.captured.map { $0.0.value(forHTTPHeaderField: "authorization") } == ["Bearer tok-1", "Bearer tok-2"])
    }

    @Test func retriesRateLimitsHonouringRetryAfter() throws {
        let sleeps = SleepLog()
        StubURLProtocol.reset([.init(status: 429, body: #"{"error":{"message":"rate limited"}}"#, headers: ["retry-after": "3"]),
                               .init(status: 529, body: #"{"error":{"message":"overloaded"}}"#),
                               .init(status: 200, body: message(goodAnswer))])
        let (url, ctx) = photo()
        let s = try namer(sleeps: sleeps).suggest(for: url, context: ctx)
        #expect(s.subject == "walnut lamp on oak sideboard")
        #expect(StubURLProtocol.captured.count == 3)
        #expect(sleeps.delays.count == 2 && sleeps.delays[0] == 3 && (2...2.25).contains(sleeps.delays[1]))
    }

    @Test func clientErrorsAreNotRetried() throws {
        for status in [400, 401] {
            StubURLProtocol.reset([.init(status: status, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"bad key"}}"#)])
            let (url, ctx) = photo()
            #expect(throws: ClaudeNamer.Error.http(status, "bad key")) { try namer().suggest(for: url, context: ctx) }
            #expect(StubURLProtocol.captured.count == 1)
        }
    }

    @Test func refusalAndTruncationAreErrors() throws {
        let (url, ctx) = photo()
        StubURLProtocol.reset([.init(status: 200, body: message("", stop: "refusal"))])
        #expect(throws: ClaudeNamer.Error.refusal) { try namer().suggest(for: url, context: ctx) }
        StubURLProtocol.reset([.init(status: 200, body: message(#"{"subject":"lamp"#, stop: "max_tokens"))])
        #expect(throws: ClaudeNamer.Error.truncated) { try namer().suggest(for: url, context: ctx) }
    }

    @Test func outputConfigRejectionFallsBackToPromptedJSON() throws {
        StubURLProtocol.reset([
            .init(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"output_config: structured outputs are not supported for this model"}}"#),
            .init(status: 200, body: message("Here you go:\n" + goodAnswer)),
        ])
        let (url, ctx) = photo()
        let s = try namer().suggest(for: url, context: ctx)
        #expect(s.subject == "walnut lamp on oak sideboard")
        #expect(try body(0)["output_config"] != nil)
        #expect(try body(1)["output_config"] == nil)
        #expect((try body(1)["system"] as? String)?.contains("Reply with only a JSON object") == true)
        #expect(s.why.contains { $0.contains("rejected output_config") })
        ClaudeNamer.structuredOutput.value = true
    }

    @Test func invalidOutputIsRejected() {
        #expect(throws: ClaudeNamer.Error.self) { try ClaudePrompt.parse("not json") }
        #expect(throws: ClaudeNamer.Error.self) { try ClaudePrompt.parse(#"{"subject":"x","kind":"panorama","merchant":"","total":"","confidence":1,"people_present":false}"#) }
        #expect(throws: ClaudeNamer.Error.self) { try ClaudePrompt.parse(#"{"subject":"","kind":"photo","merchant":"","total":"","confidence":1,"people_present":false}"#) }
    }

    /// Network failures and API errors never fail the rename: Vision names the photo instead.
    @Test func fallsBackToVisionOnFailure() throws {
        StubURLProtocol.reset([.init(status: 0, body: "", fail: .notConnectedToInternet),
                               .init(status: 0, body: "", fail: .timedOut),
                               .init(status: 0, body: "", fail: .timedOut)])
        let (url, ctx) = photo()
        let s = try FallbackNamer(primary: namer(), fallback: VisionNamer()).suggest(for: url, context: ctx)
        #expect(s.backend == "vision" && s.subject == "lamp")
        #expect(s.fallbackFrom?.hasPrefix("claude: network error") == true)
        #expect(StubURLProtocol.captured.count == 3)
    }

    @Test func screenshotMetadataWinsAndReceiptFieldsFlowThrough() throws {
        var (url, ctx) = photo()
        ctx.metadata.creatorBundleID = "com.apple.springboard"
        StubURLProtocol.reset([.init(status: 200, body: message(#"{"subject":"stripe failed payment","kind":"photo","merchant":"","total":"","confidence":0.9,"people_present":false}"#))])
        let shot = try namer().suggest(for: url, context: ctx)
        #expect(shot.kind == .screenshot && shot.subject == "stripe failed payment")
        #expect(shot.why.contains { $0.contains("kept screenshot") })

        ctx.metadata.creatorBundleID = "com.apple.camera"
        StubURLProtocol.reset([.init(status: 200, body: message(#"{"subject":"loblaws grocery receipt","kind":"receipt","merchant":"Loblaws","total":"84.12","confidence":0.9,"people_present":false}"#))])
        let r = try namer().suggest(for: url, context: ctx)
        #expect(r.kind == .receipt && r.merchant == "Loblaws" && r.total == "84-12")
        let planner = Planner(config: Config(), places: nil)
        #expect(try planner.compose(url: url, context: ctx, suggestion: r).0 == "2026-09-21_receipt_loblaws_84-12")
    }

    /// No credential: `auto` is Vision and nothing is ever sent; a direct Claude call throws before any request.
    @Test func noCredentialNeverSendsARequest() throws {
        StubURLProtocol.reset([.init(status: 200, body: message(goodAnswer))])
        let none = ClaudeAuth(environment: ["ANTHROPIC_API_KEY": "  "], keychain: { nil }, antPath: { nil })
        #expect(none.resolve() == nil, "a blank env key is not a credential")
        let auto = try Backends.resolve("auto", auth: none)
        #expect(auto is VisionNamer)
        let (url, ctx) = photo()
        var planner = Planner(config: Config(), places: nil, namer: auto)
        planner.analyzer = { _ in ctx.vision }
        #expect(planner.plan([url])[0].suggestion?.backend == "vision")
        #expect(throws: ClaudeNamer.Error.noCredential) { try namer(none).suggest(for: url, context: ctx) }
        #expect(StubURLProtocol.captured.isEmpty)
    }

    @Test func subjectCleanup() {
        #expect(ClaudePrompt.cleanSubject("A photo of Toronto skyline at dusk.", city: "Toronto", maxWords: 6) == "skyline at dusk")
        #expect(ClaudePrompt.cleanSubject("toronto skyline", city: "Toronto", maxWords: 6) == "toronto skyline")   // too short to drop
        #expect(ClaudePrompt.cleanSubject("toronto city hall", city: "Toronto", maxWords: 6) == "city hall")
        #expect(ClaudePrompt.cleanSubject("one two three four five six seven", city: nil, maxWords: 6) == "one two three four five six")
    }
}

@Suite struct ClaudeAuthTests {
    @Test func resolutionOrder() {
        final class Calls: @unchecked Sendable { var args: [[String]] = [] }
        let calls = Calls()
        let ant: @Sendable (String, [String]) -> String? = { _, a in calls.args.append(a); return "oauth-tok\n" }

        let env = ClaudeAuth(environment: ["ANTHROPIC_API_KEY": " sk-ant-env "], keychain: { "sk-ant-kc" }, antPath: { "/x/ant" }, runAnt: ant)
        #expect(env.resolve() == .apiKey("sk-ant-env", source: .environment))
        #expect(calls.args.isEmpty)

        let kc = ClaudeAuth(environment: [:], keychain: { "sk-ant-kc" }, antPath: { "/x/ant" }, runAnt: ant)
        #expect(kc.resolve() == .apiKey("sk-ant-kc", source: .keychain))

        let cli = ClaudeAuth(environment: [:], keychain: { nil }, antPath: { "/x/ant" }, runAnt: ant)
        #expect(cli.resolve() == .oauth("oauth-tok"))
        #expect(calls.args == [["auth", "print-credentials", "--access-token"]])
        _ = cli.resolve()
        #expect(calls.args.count == 1, "cached for the process")

        #expect(ClaudeAuth(environment: [:], keychain: { nil }, antPath: { nil }).resolve() == nil)
        // JSON output (i.e. the flag was ignored) is never mistaken for a token.
        #expect(ClaudeAuth(environment: [:], keychain: { nil }, antPath: { "/x/ant" }, runAnt: { _, _ in #"{"access_token":"x"}"# }).resolve() == nil)
    }

    @Test func headersAreExclusive() {
        #expect(ClaudeCredential.apiKey("k", source: .keychain).headers == ["x-api-key": "k"])
        #expect(ClaudeCredential.oauth("t").headers == ["authorization": "Bearer t", "anthropic-beta": "oauth-2025-04-20"])
    }

    @Test func statusNeverShowsSecrets() {
        let a = ClaudeAuth(environment: ["ANTHROPIC_API_KEY": "sk-ant-SECRET"], keychain: { "sk-ant-KC-SECRET" }, antPath: { "/x/ant" }, runAnt: { _, _ in "TOKEN-SECRET" })
        let text = a.report().map { "\($0.0.rawValue) \($0.1)" }.joined(separator: "\n")
        #expect(!text.contains("SECRET"))
        #expect(text.contains("set") && text.contains("stored") && text.contains("logged in"))
    }

    @Test func autoUsesClaudeOnlyWithACredential() throws {
        let cred = ClaudeAuth(environment: ["ANTHROPIC_API_KEY": "sk-ant-x"], keychain: { nil }, antPath: { nil })
        #expect(try Backends.resolve("auto", auth: cred).id == "claude")
        #expect(try Backends.resolve("auto", auth: .none).id == "vision")
        var c = Config(); c.claudeInAuto = false
        #expect(try Backends.resolve("auto", config: c, auth: cred).id == "vision")
        #expect(try Backends.resolve("claude", auth: cred) is FallbackNamer)
    }

    @Test func configDefaults() throws {
        #expect(Config().claudeModel == "claude-haiku-4-5")
        let c = try Config.parse("[claude]\nmodel = \"claude-sonnet-4-6\"\nauto = false\n")
        #expect(c.claudeModel == "claude-sonnet-4-6" && c.claudeInAuto == false)
    }
}

// Same suite as ClaudeNamerTests: StubURLProtocol is shared state, so these must not run in parallel with it.
extension ClaudeNamerTests {
    @Test func validateUsesModelsEndpoint() throws {
        StubURLProtocol.reset([.init(status: 200, body: "{}")])
        #expect(ClaudeAuth.validate(key: " sk-ant-good\n", transport: StubURLProtocol.transport) == .valid)
        let req = try #require(StubURLProtocol.captured.first?.0)
        #expect(req.httpMethod == "GET" && req.url?.path == "/v1/models")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-ant-good")
    }

    @Test func rejectedAndUnreachable() {
        StubURLProtocol.reset([.init(status: 401, body: "{}"), .init(status: 529, body: "{}"), .init(status: 0, body: "", fail: .notConnectedToInternet)])
        guard case .rejected = ClaudeAuth.validate(key: "sk-ant-bad", transport: StubURLProtocol.transport) else { Issue.record("401"); return }
        guard case .unreachable = ClaudeAuth.validate(key: "sk-ant-x", transport: StubURLProtocol.transport) else { Issue.record("529"); return }
        guard case .unreachable = ClaudeAuth.validate(key: "sk-ant-x", transport: StubURLProtocol.transport) else { Issue.record("offline"); return }
        guard case .rejected = ClaudeAuth.validate(key: "not a key", transport: StubURLProtocol.transport) else { Issue.record("format"); return }
    }
}
