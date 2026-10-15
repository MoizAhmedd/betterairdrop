import Foundation

/// Where hosted naming gets the BetterAirdrop Pro license key. The Pro code supplies the real
/// source (a key only while Pro is active or in its grace period) with a one-line conformance;
/// `LicenseFileKeySource` stands in until then.
public protocol LicenseKeySource: Sendable {
    /// The key to send, or nil when this Mac has no usable Pro license.
    func licenseKey() -> String?
}

/// Reads `license` in the support directory (`~/Library/Application Support/betterairdrop/license`):
/// the Pro license file (JSON with a `key`) or, for testing, a file holding just the key.
public struct LicenseFileKeySource: LicenseKeySource {
    public var url: URL

    public init(url: URL = Paths.supportDirectory.appendingPathComponent("license")) { self.url = url }

    public func licenseKey() -> String? {
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1024 else { return nil }
        let raw: String?
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = obj["key"] as? String
        } else {
            raw = String(data: data, encoding: .utf8)
        }
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty || key.contains(where: \.isWhitespace) ? nil : key
    }
}

/// Claude-quality names for Pro, with no API key of the user's: the same upload and context as
/// `ClaudeNamer`, sent to BetterAirdrop's Worker (`hosted/`), which checks the license with Polar
/// and asks Claude with BetterAirdrop's key. The Worker fixes the model and the prompt; the answer
/// is the one `ClaudePrompt.parse` reads.
///
/// What leaves the Mac is what `ClaudeNamer` sends (a metadata-free 768 px JPEG and the text
/// context), plus the license key. The Worker stores no photos, context or names.
public struct HostedNamer: Namer {
    public let id = "hosted"
    public static let defaultBaseURL = URL(string: "https://api.betterairdrop.com")!

    public var baseURL: URL
    public var license: any LicenseKeySource
    public var transport: any HTTPTransport
    /// The Worker's own worst case (a Polar check and two tries at Claude) is about 25 s.
    public var timeout: TimeInterval = 30
    /// One retry for network errors and the Worker's 500/502/504. Never for 403, 422, 429 or 503.
    public var maxAttempts = 2
    public var imageSize = 768
    /// Injected in tests so retries don't really sleep, and so limits can expire.
    public var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    public var now: @Sendable () -> Date = { Date() }

    public init(baseURL: URL = HostedNamer.defaultBaseURL, license: any LicenseKeySource = LicenseFileKeySource(),
                transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL; self.license = license; self.transport = transport
    }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case noLicense
        /// 403: Polar says the key is unknown, revoked or expired.
        case licenseInvalid
        /// 429: this license's names for the month are used up.
        case monthlyLimit(resets: Date?)
        /// 429: hosted naming as a whole reached its daily limit.
        case dailyLimit(resets: Date?)
        case refusal
        /// 503: the license can't be checked right now (Polar is down).
        case unavailable(String)
        case http(Int, String)
        case network(String)

        public var description: String {
            switch self {
            case .noLicense: "no BetterAirdrop Pro license on this Mac"
            case .licenseInvalid: "license invalid: this BetterAirdrop Pro key is unknown, revoked or expired"
            case .monthlyLimit(let d): "monthly hosted limit reached" + (d.map { "; resets \(Self.day($0))" } ?? "")
            case .dailyLimit(let d): "hosted naming reached its daily limit" + (d.map { "; resets \(Self.time($0))" } ?? "")
            case .refusal: "Claude declined to describe this image"
            case .unavailable(let why): "hosted naming is unavailable: \(why)"
            case .http(let code, let msg): "hosted naming returned \(code): \(msg)"
            case .network(let why): "network error: \(why)"
            }
        }

        /// The month resets at midnight UTC on the 1st, so the UTC date reads right ("Nov 1, 2026").
        static func day(_ d: Date) -> String {
            let f = DateFormatter()
            f.dateStyle = .medium; f.timeStyle = .none; f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: d)
        }

        /// The daily limit resets at midnight UTC: shown in local time ("Oct 15, 2026 at 8:00 PM").
        static func time(_ d: Date) -> String {
            let f = DateFormatter()
            f.dateStyle = .medium; f.timeStyle = .short
            return f.string(from: d)
        }
    }

    public func availability() -> Availability {
        guard let key = license.licenseKey() else { return .unavailable(Error.noLicense.description) }
        if let blocked = Self.blocks.reason(key: key, now: now()) { return .unavailable(blocked.description) }
        return .ready
    }

    /// Why hosted naming is skipped right now (license invalid, a limit), for the engine status. Nil if it isn't.
    public static func currentProblem(license: any LicenseKeySource = LicenseFileKeySource(), now: Date = Date()) -> String? {
        license.licenseKey().flatMap { blocks.reason(key: $0, now: now)?.description }
    }

    public func suggest(for url: URL, context ctx: PhotoContext) throws -> NameSuggestion {
        guard let key = license.licenseKey() else { throw Error.noLicense }
        if let blocked = Self.blocks.reason(key: key, now: now()) { throw blocked }
        var timings = StageTimings()
        let upload = try CloudUpload(url, context: ctx, maxPixelSize: imageSize, timings: &timings)
        let (data, remaining) = try call(upload, key: key, timings: &timings)
        let answer = try ClaudePrompt.parse(String(decoding: data, as: UTF8.self))
        var why = ["sent \(upload.summary) to BetterAirdrop's hosted naming (Claude, with this Mac's Pro license)"]
        if let remaining { why.append("\(remaining) hosted name\(remaining == 1 ? "" : "s") left this month") }
        return upload.suggestion(answer, context: ctx, backend: id, why: why, timings: timings, usage: nil)
    }

    /// One logical request, with a retry for network errors and 500/502/504. Returns the 200 body
    /// and the names left this month.
    func call(_ upload: CloudUpload, key: String, timings: inout StageTimings) throws -> (Data, Int?) {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/name"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["image": upload.image.base64EncodedString(), "context": upload.context])

        var attempt = 0
        while true {
            attempt += 1
            let response: HTTPURLResponse, data: Data
            do {
                (response, data) = try timings.time(.hosted) { try transport.send(req) }
            } catch {
                if attempt < maxAttempts { timings.time(.hosted) { sleep(CloudUpload.backoff(attempt, retryAfter: nil)) }; continue }
                throw Error.network((error as NSError).localizedDescription)
            }
            let status = response.statusCode
            if status == 200 {
                return (data, response.value(forHTTPHeaderField: "x-names-remaining").flatMap { Int($0) })
            }
            let (type, message, resets) = Self.errorBody(data)
            let failure: Error
            switch status {
            case 401, 403: failure = .licenseInvalid
            case 429: failure = type == "daily_limit" ? .dailyLimit(resets: resets) : .monthlyLimit(resets: resets)
            case 422 where type == "refusal": failure = .refusal
            case 503: failure = .unavailable(message)
            case 500, 504, 502 where type != "bad_output":
                if attempt < maxAttempts { timings.time(.hosted) { sleep(CloudUpload.backoff(attempt, retryAfter: nil)) }; continue }
                failure = .http(status, message)
            default: failure = .http(status, message)
            }
            Self.blocks.record(failure, key: key)
            throw failure
        }
    }

    /// `{"type":"error","error":{"type","message","resets_at"?}}`, the Worker's error shape.
    static func errorBody(_ data: Data) -> (type: String?, message: String, resets: Date?) {
        let e = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let resets = (e?["resets_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return (e?["type"] as? String, e?["message"] as? String ?? ClaudeNamer.errorMessage(data), resets)
    }

    // MARK: - Remembered refusals

    /// What the Worker last refused, for this process: later photos skip the request (and go
    /// straight to the fallback) until it could have changed. A 403 holds until the key changes;
    /// a limit holds until its reset time.
    static let blocks = Blocks()

    final class Blocks: @unchecked Sendable {
        private let lock = NSLock()
        private var invalidKey: String?
        private var monthly: (key: String, until: Date)?
        private var daily: Date?

        func reason(key: String, now: Date) -> Error? {
            lock.lock(); defer { lock.unlock() }
            if invalidKey == key { return .licenseInvalid }
            if let m = monthly, m.key == key, now < m.until { return .monthlyLimit(resets: m.until) }
            if let d = daily, now < d { return .dailyLimit(resets: d) }
            return nil
        }

        func record(_ e: Error, key: String) {
            lock.lock(); defer { lock.unlock() }
            switch e {
            case .licenseInvalid: invalidKey = key
            case .monthlyLimit(let d?): monthly = (key, d)
            case .dailyLimit(let d?): daily = d
            default: break
            }
        }

        func reset() {
            lock.lock(); invalidKey = nil; monthly = nil; daily = nil; lock.unlock()
        }
    }
}
