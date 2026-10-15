@testable import BetterAirdropCore
import Foundation
import Testing

/// Canned HTTP for hosted naming. Its own state, so these suites can run alongside
/// ClaudeNamerTests (which owns StubURLProtocol).
final class HostedStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Reply = StubURLProtocol.Reply
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
        c.protocolClasses = [HostedStubProtocol.self]
        return URLSessionTransport(configuration: c)
    }
}

struct FixedLicense: LicenseKeySource {
    var key: String?
    func licenseKey() -> String? { key }
}

func hostedError(_ type: String, _ message: String, resets: String? = nil) -> String {
    let extra = resets.map { #","resets_at":"\#($0)""# } ?? ""
    return #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"\#(extra)}}"#
}

@Suite(.serialized) struct HostedNamerTests {
    let dir = TestImages.TempDir()
    static let key = "BA_1234ABCD-5678-EF90"

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_792_065_600) }   // 2026-10-15 12:00 UTC

    func namer(_ key: String? = HostedNamerTests.key, clock: Clock = Clock()) -> HostedNamer {
        HostedNamer.blocks.reset()
        HostedNamer.usage.reset()
        var n = HostedNamer(license: FixedLicense(key: key), transport: HostedStubProtocol.transport)
        n.sleep = { _ in }
        n.now = { clock.now }
        return n
    }

    func photo() -> (URL, PhotoContext) {
        let url = TestImages.write(dir.path("IMG_\(UUID().uuidString.prefix(4)).HEIC"), type: .heic, meta: .init(), width: 2400, height: 1600)
        var m = try! PhotoMetadata.read(url)
        m.creatorBundleID = "com.apple.camera"
        let ctx = PhotoContext(file: url.path, metadata: m, place: Place(city: "Toronto", countryCode: "CA", distanceKm: 3),
                               vision: VisionResult(labels: [.init("lamp", 0.7)], lines: []), kind: .photo, kindReason: "default")
        return (url, ctx)
    }

    @Test func success() throws {
        HostedStubProtocol.reset([.init(status: 200, body: goodAnswer, headers: ["x-names-remaining": "47", "x-names-reset": "2026-11-01T00:00:00Z"])])
        let (url, ctx) = photo()
        let s = try namer().suggest(for: url, context: ctx)
        #expect(s.subject == "walnut lamp on oak sideboard" && s.kind == .photo && s.backend == "hosted" && s.confidence == 0.92)
        #expect(s.usage == nil, "BetterAirdrop's key pays, not the user's")
        #expect(s.why.contains("47 hosted names left this month"))
        #expect(s.timings?[.hosted] != nil && s.timings?[.encode] != nil)

        let (req, data) = try #require(HostedStubProtocol.captured.first)
        #expect(req.url?.absoluteString == "https://api.betterairdrop.com/v1/name")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer \(Self.key)")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(Set(body.keys) == ["image", "context"], "only the image and the context: the Worker owns the prompt")
        #expect(body["context"] == ClaudePrompt.context(ctx))
        let jpeg = try #require(Data(base64Encoded: body["image"] ?? ""))
        #expect(jpeg.starts(with: [0xFF, 0xD8]) && jpeg.count < 400 * 1024)
    }

    @Test func baseURLComesFromConfig() throws {
        let c = try Config.parse("backend = \"hosted\"\n[hosted]\nurl = \"http://127.0.0.1:8787\"\n")
        #expect(c.backend == "hosted" && c.hostedURL.absoluteString == "http://127.0.0.1:8787")
        #expect(Config().hostedURL == HostedNamer.defaultBaseURL)
        #expect(throws: Config.ParseError.self) { try Config.parse("[hosted]\nurl = \"api.betterairdrop.com\"\n") }
        let n = try #require(Backends.make("hosted", config: c, license: FixedLicense(key: Self.key)) as? HostedNamer)
        #expect(n.baseURL.absoluteString == "http://127.0.0.1:8787")
    }

    @Test func licenseInvalid() throws {
        HostedStubProtocol.reset([.init(status: 403, body: hostedError("license_invalid", "not valid"))])
        let (url, ctx) = photo()
        let n = namer()
        #expect(throws: HostedNamer.Error.licenseInvalid) { try n.suggest(for: url, context: ctx) }
        #expect(HostedNamer.Error.licenseInvalid.description.hasPrefix("license invalid"))

        // Later photos skip the request and go straight to Vision, saying why.
        #expect(n.availability() == .unavailable(HostedNamer.Error.licenseInvalid.description))
        #expect(HostedNamer.currentProblem(key: Self.key) == HostedNamer.Error.licenseInvalid.description)
        #expect(HostedNamer.lastUsage()?.lastError == HostedNamer.Error.licenseInvalid.description)
        let s = try FallbackNamer(primary: n, fallback: VisionNamer()).suggest(for: url, context: ctx)
        #expect(s.backend == "vision" && s.fallbackFrom?.contains("license invalid") == true)
        #expect(HostedStubProtocol.captured.count == 1)

        // A different key (the user activated a new one) is tried again.
        var other = n
        other.license = FixedLicense(key: "BA_OTHER-KEY-0000")
        #expect(other.availability() == .ready)
    }

    @Test func monthlyLimit() throws {
        HostedStubProtocol.reset([.init(status: 429, body: hostedError("monthly_limit", "used up", resets: "2026-11-01T00:00:00Z"),
                                        headers: ["retry-after": "1468800"])])
        let (url, ctx) = photo()
        let clock = Clock()
        let n = namer(clock: clock)
        let resets = try #require(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(throws: HostedNamer.Error.monthlyLimit(resets: resets)) { try n.suggest(for: url, context: ctx) }
        let message = HostedNamer.Error.monthlyLimit(resets: resets).description
        #expect(message == "monthly hosted limit reached; resets \(HostedNamer.Error.day(resets))")
        #expect(HostedNamer.Error.day(resets).contains("1") && !HostedNamer.Error.day(resets).contains("31"), "the UTC date, not Oct 31 in the Americas")
        #expect(HostedStubProtocol.captured.count == 1, "429 is never retried")

        // Until the reset: skipped, with the reason. After it: tried again.
        #expect(n.availability() == .unavailable(message))
        let s = try FallbackNamer(primary: n, fallback: VisionNamer()).suggest(for: url, context: ctx)
        #expect(s.backend == "vision" && s.fallbackFrom?.contains("monthly hosted limit reached; resets") == true)
        #expect(HostedStubProtocol.captured.count == 1)
        clock.now = resets.addingTimeInterval(1)
        #expect(n.availability() == .ready)
    }

    @Test func dailyLimitIsItsOwnMessage() throws {
        HostedStubProtocol.reset([.init(status: 429, body: hostedError("daily_limit", "busy", resets: "2026-10-16T00:00:00Z"))])
        let (url, ctx) = photo()
        #expect(throws: HostedNamer.Error.self) { try namer().suggest(for: url, context: ctx) }
        let resets = try #require(ISO8601DateFormatter().date(from: "2026-10-16T00:00:00Z"))
        #expect(HostedNamer.Error.dailyLimit(resets: resets).description.hasPrefix("hosted naming reached its daily limit; resets "))
    }

    @Test func timeoutFallsBackToVision() throws {
        HostedStubProtocol.reset([.init(status: 0, body: "", fail: .timedOut), .init(status: 0, body: "", fail: .timedOut)])
        let (url, ctx) = photo()
        let s = try FallbackNamer(primary: namer(), fallback: VisionNamer()).suggest(for: url, context: ctx)
        #expect(s.backend == "vision" && s.subject == "lamp")
        #expect(s.fallbackFrom?.hasPrefix("hosted: network error") == true)
        #expect(HostedStubProtocol.captured.count == 2, "one retry")
        #expect(namer().availability() == .ready, "a timeout doesn't block the next photo")
    }

    @Test func retriesOnlyServerErrors() throws {
        let (url, ctx) = photo()
        HostedStubProtocol.reset([.init(status: 502, body: hostedError("upstream_error", "Claude couldn't be reached")),
                                  .init(status: 200, body: goodAnswer)])
        #expect(try namer().suggest(for: url, context: ctx).backend == "hosted")
        #expect(HostedStubProtocol.captured.count == 2)

        for (status, type) in [(503, "license_check_unavailable"), (422, "refusal"), (502, "bad_output"), (413, "payload_too_large")] {
            HostedStubProtocol.reset([.init(status: status, body: hostedError(type, "no")), .init(status: 200, body: goodAnswer)])
            #expect(throws: HostedNamer.Error.self) { try namer().suggest(for: url, context: ctx) }
            #expect(HostedStubProtocol.captured.count == 1, "\(status) \(type) isn't retried")
        }
        HostedStubProtocol.reset([.init(status: 422, body: hostedError("refusal", "declined"))])
        #expect(throws: HostedNamer.Error.refusal) { try namer().suggest(for: url, context: ctx) }
    }

    @Test func noLicenseSkipsHosted() throws {
        HostedStubProtocol.reset([.init(status: 200, body: goodAnswer)])
        let (url, ctx) = photo()
        let n = namer(nil)
        #expect(n.availability() == .unavailable("no BetterAirdrop Pro license on this Mac"))
        #expect(throws: HostedNamer.Error.noLicense) { try n.suggest(for: url, context: ctx) }
        let s = try FallbackNamer(primary: n, fallback: VisionNamer()).suggest(for: url, context: ctx)
        #expect(s.backend == "vision")
        #expect(HostedStubProtocol.captured.isEmpty)

        let none = FixedLicense(key: nil)
        #expect(try Backends.resolve("auto", auth: .none, apple: Self.apple(false), license: none) is VisionNamer)
        #expect(throws: BackendError.unavailable("hosted", reason: "no BetterAirdrop Pro license on this Mac")) {
            try Backends.resolve("hosted", auth: .none, license: none)
        }
        #expect(HostedNamer.currentProblem(key: nil) == nil)
        #expect(try Backends.resolve("auto", auth: .none, apple: Self.apple(false)) is VisionNamer, "no license passed: no hosted")
    }

    static func apple(_ ready: Bool) -> AppleFMNamer {
        var a = AppleFMNamer()
        a.status = { ready ? .available : .notEnabled }
        return a
    }

    /// Your own Claude key → hosted (with a license) → Apple Intelligence → Vision; each but Vision falls back to Vision.
    @Test func autoOrder() throws {
        HostedNamer.blocks.reset()
        let key = ClaudeAuth(environment: ["ANTHROPIC_API_KEY": "sk-ant-x"], storedKey: { nil }, antPath: { nil })
        let pro = FixedLicense(key: Self.key), none = FixedLicense(key: nil)
        func auto(_ auth: ClaudeAuth, _ apple: Bool, _ license: FixedLicense, _ config: Config = Config()) throws -> any Namer {
            try Backends.resolve("auto", config: config, auth: auth, apple: Self.apple(apple), license: license)
        }
        #expect(try auto(key, true, pro).id == "claude")
        #expect((try auto(key, true, pro) as? FallbackNamer)?.fallback.id == "vision", "your own key still falls back to Vision")
        // Hosted (Pro) falls back to Apple Intelligence when it's ready, else Vision.
        let hosted = try auto(.none, true, pro)
        #expect(hosted.id == "hosted" && (hosted as? FallbackNamer)?.fallback.id == "apple")
        #expect(((hosted as? FallbackNamer)?.fallback as? FallbackNamer)?.fallback.id == "vision")
        #expect((try auto(.none, false, pro) as? FallbackNamer)?.fallback.id == "vision")
        #expect(try auto(.none, true, none).id == "apple")
        #expect(try auto(.none, false, none).id == "vision")
        #expect(Backends.isCloud(hosted))

        // claude.auto = false keeps auto on-device: no Claude and no hosted.
        var local = Config(); local.claudeInAuto = false
        #expect(try auto(key, true, pro, local).id == "apple")
        #expect(try auto(key, false, pro, local).id == "vision")

        // An explicit choice is wrapped the same way.
        let explicit = try Backends.resolve("hosted", auth: .none, apple: Self.apple(true), license: pro)
        #expect((explicit as? FallbackNamer)?.fallback.id == "apple")

        // Over a limit, hosted is still the engine (it picks up after the reset); photos go to the fallback meanwhile.
        HostedNamer.blocks.record(.monthlyLimit(resets: Date().addingTimeInterval(86_400)), key: Self.key)
        #expect(try auto(.none, true, pro).id == "hosted")
        HostedNamer.blocks.reset()
    }

    static func appleNamer(_ subject: String = "walnut lamp on sideboard") -> AppleFMNamer {
        var a = apple(true)
        a.generate = { _, _ in ClaudePrompt.Answer(subject: subject, kind: "photo", confidence: 0.8) }
        return a
    }

    /// Hosted fails (offline, timeout) or is skipped (403, a limit): Apple Intelligence names it when it's ready.
    @Test func failuresFallBackToAppleIntelligence() throws {
        let (url, ctx) = photo()
        let chain = { (n: HostedNamer) in FallbackNamer(primary: n, fallback: Backends.onDevice(Self.appleNamer())) }

        HostedStubProtocol.reset([.init(status: 0, body: "", fail: .timedOut), .init(status: 0, body: "", fail: .timedOut)])
        let offline = try chain(namer()).suggest(for: url, context: ctx)
        #expect(offline.backend == "apple" && offline.subject == "walnut lamp on sideboard")
        #expect(offline.fallbackFrom?.hasPrefix("hosted: network error") == true)

        HostedStubProtocol.reset([.init(status: 429, body: hostedError("monthly_limit", "used up", resets: "2026-11-01T00:00:00Z"))])
        let n = namer()
        #expect(try chain(n).suggest(for: url, context: ctx).backend == "apple")
        let skipped = try chain(n).suggest(for: url, context: ctx)
        #expect(skipped.backend == "apple" && skipped.fallbackFrom?.contains("monthly hosted limit reached") == true)
        #expect(HostedStubProtocol.captured.count == 1, "skipped without a request")

        HostedStubProtocol.reset([.init(status: 403, body: hostedError("license_invalid", "no"))])
        #expect(try chain(namer()).suggest(for: url, context: ctx).backend == "apple")

        // Apple Intelligence not ready: Vision, as before.
        HostedStubProtocol.reset([.init(status: 0, body: "", fail: .timedOut), .init(status: 0, body: "", fail: .timedOut)])
        let vision = try FallbackNamer(primary: namer(), fallback: Backends.onDevice(Self.apple(false))).suggest(for: url, context: ctx)
        #expect(vision.backend == "vision")
    }

    /// A camera photo skips Vision while hosted is ready; when hosted fails, the planner runs Vision
    /// so Apple Intelligence has labels to work from.
    @Test func plannerGivesAppleIntelligenceVisionsLabels() throws {
        HostedStubProtocol.reset([.init(status: 0, body: "", fail: .timedOut), .init(status: 0, body: "", fail: .timedOut)])
        let (url, _) = photo()
        var apple = Self.apple(true)
        apple.generate = { prompt, _ in
            ClaudePrompt.Answer(subject: prompt.contains("lamp") ? "lamp on a table" : "no labels", kind: "photo", confidence: 0.7)
        }
        var planner = Planner(config: Config(), places: nil, namer: FallbackNamer(primary: namer(), fallback: Backends.onDevice(apple)))
        planner.analyzer = { _ in VisionResult(labels: [.init("lamp", 0.7)], lines: []) }
        let s = try #require(planner.plan([url])[0].suggestion)
        #expect(s.backend == "apple" && s.subject == "lamp on a table")
        #expect(s.fallbackFrom?.hasPrefix("hosted: network error") == true)
    }

    @Test func usageIsRemembered() throws {
        let clock = Clock()
        HostedStubProtocol.reset([.init(status: 200, body: goodAnswer, headers: ["x-names-remaining": "47", "x-names-reset": "2026-11-01T00:00:00Z"]),
                                  .init(status: 0, body: "", fail: .timedOut), .init(status: 0, body: "", fail: .timedOut),
                                  .init(status: 429, body: hostedError("monthly_limit", "used up", resets: "2026-11-01T00:00:00Z"))])
        let (url, ctx) = photo()
        let n = namer(clock: clock)
        #expect(HostedNamer.lastUsage() == nil, "nothing heard yet")
        let resets = try #require(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))

        _ = try n.suggest(for: url, context: ctx)
        #expect(HostedNamer.lastUsage(now: clock.now) == HostedUsage(remaining: 47, resetsAt: resets, lastError: nil, updatedAt: clock.now))

        #expect(throws: HostedNamer.Error.self) { try n.suggest(for: url, context: ctx) }
        let offline = try #require(HostedNamer.lastUsage(now: clock.now))
        #expect(offline.remaining == 47 && offline.lastError?.hasPrefix("network error") == true, "an error keeps the count")

        #expect(throws: HostedNamer.Error.self) { try n.suggest(for: url, context: ctx) }
        let capped = try #require(HostedNamer.lastUsage(now: clock.now))
        #expect(capped.remaining == 0 && capped.resetsAt == resets && capped.lastError?.hasPrefix("monthly hosted limit reached") == true)

        // After the reset the old count and error are dropped.
        #expect(HostedNamer.lastUsage(now: resets.addingTimeInterval(1)) == HostedUsage(updatedAt: clock.now))

        // A seed (the app's last report) never replaces what this process heard.
        HostedNamer.seedUsage(HostedUsage(remaining: 400, updatedAt: clock.now))
        #expect(HostedNamer.lastUsage(now: clock.now)?.remaining == 0)
        HostedNamer.usage.reset()
        HostedNamer.seedUsage(HostedUsage(remaining: 400, updatedAt: clock.now))
        #expect(HostedNamer.lastUsage(now: clock.now)?.remaining == 400)
        let json = String(decoding: try JSONEncoder().encode(HostedUsage(remaining: 3, lastError: "x", updatedAt: clock.now)), as: UTF8.self)
        #expect(json.contains("\"last_error\"") && json.contains("\"updated_at\""))
    }
}

/// hosted/src/prompt.json is the Worker's copy of the prompt: it must match ClaudePrompt.
@Suite struct HostedPromptTests {
    @Test func workerPromptMatchesTheApp() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("hosted/src/prompt.json"))
        let p = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(p["system"] as? String == ClaudePrompt.instructions, "update hosted/src/prompt.json's system from ClaudePrompt.instructions")
        #expect(p["json_instructions"] as? String == ClaudePrompt.jsonInstructions)
        #expect(p["kinds"] as? [String] == ClaudePrompt.kinds)
        #expect(NSDictionary(dictionary: p["schema"] as? [String: Any] ?? [:]).isEqual(to: ClaudePrompt.schema))
    }
}
