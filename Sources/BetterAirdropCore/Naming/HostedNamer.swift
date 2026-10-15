import Foundation

/// Where hosted naming gets the BetterAirdrop Pro license key. BetterAirdropKit's `LicenseStore`
/// is the real source: a key only while Pro is active or in its grace period.
public protocol LicenseKeySource: Sendable {
    /// The key to send, or nil when this Mac has no usable Pro license.
    func licenseKey() -> String?
}

/// No license: hosted naming is never used. The default where no Pro license is passed in.
public struct NoLicenseKey: LicenseKeySource {
    public init() {}
    public func licenseKey() -> String? { nil }
}

/// What hosted naming last heard from the server, for the engine status and `status --json`:
/// names left this month (the `X-Names-Remaining` / `X-Names-Reset` headers) and the last error.
public struct HostedUsage: Codable, Equatable, Sendable {
    public var remaining: Int?
    public var resetsAt: Date?
    public var lastError: String?
    public var updatedAt: Date

    public init(remaining: Int? = nil, resetsAt: Date? = nil, lastError: String? = nil, updatedAt: Date) {
        self.remaining = remaining; self.resetsAt = resetsAt; self.lastError = lastError; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case remaining
        case resetsAt = "resets_at", lastError = "last_error", updatedAt = "updated_at"
    }

    /// Once the month has reset, the count and any error from before are out of date.
    public func current(now: Date) -> HostedUsage {
        guard let r = resetsAt, now >= r else { return self }
        return HostedUsage(updatedAt: updatedAt)
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

    public init(baseURL: URL = HostedNamer.defaultBaseURL, license: any LicenseKeySource = NoLicenseKey(),
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

    /// Why hosted naming is skipped right now for this key (license invalid, a limit), for the
    /// engine status. Nil if it isn't.
    public static func currentProblem(key: String?, now: Date = Date()) -> String? {
        key.flatMap { blocks.reason(key: $0, now: now)?.description }
    }

    /// What the server last said in this process (nil before the first request).
    public static func lastUsage(now: Date = Date()) -> HostedUsage? { usage.get()?.current(now: now) }

    /// Starts from what an earlier run saw (the app's last report), so the count shows before the
    /// first photo. Never overwrites something this process heard itself.
    public static func seedUsage(_ u: HostedUsage) { usage.seed(u) }

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
                let failure = Error.network((error as NSError).localizedDescription)
                Self.usage.record(error: failure.description, now: now())
                throw failure
            }
            let status = response.statusCode
            if status == 200 {
                let remaining = response.value(forHTTPHeaderField: "x-names-remaining").flatMap { Int($0) }
                let resets = response.value(forHTTPHeaderField: "x-names-reset").flatMap { ISO8601DateFormatter().date(from: $0) }
                Self.usage.record(remaining: remaining, resets: resets, error: nil, now: now())
                return (data, remaining)
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
            if case .monthlyLimit(let d) = failure {
                Self.usage.record(remaining: 0, resets: d, error: failure.description, now: now())
            } else {
                Self.usage.record(error: failure.description, now: now())
            }
            throw failure
        }
    }

    /// `{"type":"error","error":{"type","message","resets_at"?}}`, the Worker's error shape.
    static func errorBody(_ data: Data) -> (type: String?, message: String, resets: Date?) {
        let e = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let resets = (e?["resets_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return (e?["type"] as? String, e?["message"] as? String ?? ClaudeNamer.errorMessage(data), resets)
    }

    // MARK: - Remembered usage and refusals

    static let usage = UsageBox()

    final class UsageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: HostedUsage?
        private var heard = false

        func get() -> HostedUsage? { lock.lock(); defer { lock.unlock() }; return value }

        func seed(_ u: HostedUsage) { lock.lock(); if !heard { value = u }; lock.unlock() }

        /// A success (`error` nil) sets the count; an error keeps the last count unless it carries one.
        func record(remaining: Int? = nil, resets: Date? = nil, error: String?, now: Date) {
            lock.lock(); defer { lock.unlock() }
            heard = true
            var u = value ?? HostedUsage(updatedAt: now)
            if remaining != nil || error == nil { u.remaining = remaining; u.resetsAt = resets ?? u.resetsAt }
            u.lastError = error
            u.updatedAt = now
            value = u
        }

        func reset() { lock.lock(); value = nil; heard = false; lock.unlock() }
    }

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
