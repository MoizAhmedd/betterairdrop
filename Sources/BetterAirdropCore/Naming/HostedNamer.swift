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
///
/// Without a license, `trial` (the free trial, `pro_trial`) sends the install's random trial ID
/// instead, for photos only, until the server's 25 are used up.
public struct HostedNamer: Namer {
    public let id = "hosted"
    public static let defaultBaseURL = URL(string: "https://api.betterairdrop.com")!

    public var baseURL: URL
    public var license: any LicenseKeySource
    /// The free trial, used when there's no license. Nil = license only.
    public var trial: TrialStore?
    public var transport: any HTTPTransport
    /// The Worker's own worst case (a Polar check, then two requests to Claude with a retry each) is 29 s.
    public var timeout: TimeInterval = 30
    /// One retry for network errors and the Worker's 500/502/504. Never for 403, 422, 429 or 503.
    public var maxAttempts = 2
    public var imageSize = 768
    /// Injected in tests so retries don't really sleep, and so limits can expire.
    public var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    public var now: @Sendable () -> Date = { Date() }

    public init(baseURL: URL = HostedNamer.defaultBaseURL, license: any LicenseKeySource = NoLicenseKey(),
                trial: TrialStore? = nil, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL; self.license = license; self.trial = trial; self.transport = transport
    }

    /// What a request is sent with: `Bearer <license key>`, else `Trial <install ID>`. `block` is
    /// what `blocks` remembers refusals under.
    struct Credential {
        var authorization: String
        var block: String
        var isTrial: Bool
    }

    func credential() -> Credential? {
        if let key = license.licenseKey() { return Credential(authorization: "Bearer \(key)", block: key, isTrial: false) }
        if let id = trial?.activeID() { return Credential(authorization: "Trial \(id)", block: Self.trialBlock(id), isTrial: true) }
        return nil
    }

    static func trialBlock(_ id: String) -> String { "trial:\(id)" }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case noLicense
        /// 403: Polar says the key is unknown, revoked or expired.
        case licenseInvalid
        /// 429: this license's names for the month are used up.
        case monthlyLimit(resets: Date?)
        /// 429: hosted naming as a whole reached its daily limit.
        case dailyLimit(resets: Date?)
        /// The free trial's names are used up (403 `trial_used_up`, or the last one was used).
        case trialUsedUp
        /// 429: the free trial reached its daily limit (all trials, or this network's share).
        case trialDailyLimit(resets: Date?)
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
            case .trialUsedUp: "the free Pro naming trial is used up"
            case .trialDailyLimit(let d): "the free Pro naming trial reached today's limit" + (d.map { "; back \(Self.time($0))" } ?? "")
            case .refusal: "Claude declined to describe this image"
            case .unavailable(let why): "hosted naming is unavailable: \(why)"
            case .http(let code, let msg): "hosted naming returned \(code): \(msg)"
            case .network(let why): "network error: \(why)"
            }
        }

        /// The same in plain words, for the app's "Now using". `description` stays as it is: it's
        /// `last_error` in `status --json`, and the CLI's notes.
        public var message: String {
            switch self {
            case .licenseInvalid: "your Pro key isn't valid any more"
            case .monthlyLimit(let d): "this month's Pro names are used up" + (d.map { "; more on \(Self.day($0))" } ?? "")
            case .dailyLimit(let d): "Pro naming hit today's limit" + (d.map { "; back \(Self.time($0))" } ?? "")
            default: description
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
        guard let c = credential() else {
            return .unavailable((trial?.isUsedUp == true ? Error.trialUsedUp : Error.noLicense).description)
        }
        if let blocked = Self.blocks.reason(key: c.block, now: now()) { return .unavailable(blocked.description) }
        return .ready
    }

    /// Why hosted naming is skipped right now for this key (license invalid, a limit), for the
    /// app's engine status, in plain words (`Error.message`). Nil if it isn't.
    public static func currentProblem(key: String?, now: Date = Date()) -> String? {
        key.flatMap { blocks.reason(key: $0, now: now)?.message }
    }

    /// The same for the free trial's install ID.
    public static func currentTrialProblem(id: String?, now: Date = Date()) -> String? {
        currentProblem(key: id.map(trialBlock), now: now)
    }

    /// What the server last said in this process (nil before the first request).
    public static func lastUsage(now: Date = Date()) -> HostedUsage? { usage.get()?.current(now: now) }

    /// Starts from what an earlier run saw (the app's last report), so the count shows before the
    /// first photo. Never overwrites something this process heard itself.
    public static func seedUsage(_ u: HostedUsage) { usage.seed(u) }

    public func suggest(for url: URL, context ctx: PhotoContext) throws -> NameSuggestion {
        guard let c = credential() else { throw trial?.isUsedUp == true ? Error.trialUsedUp : Error.noLicense }
        if let blocked = Self.blocks.reason(key: c.block, now: now()) { throw blocked }
        var timings = StageTimings()
        if let doc = ctx.document {
            guard !c.isTrial else { throw Error.noLicense }   // the trial names photos only
            return try suggestDocument(doc, credential: c, timings: &timings)
        }
        let upload = try CloudUpload(url, context: ctx, maxPixelSize: imageSize, timings: &timings)
        let (data, remaining) = try call("v1/name", ["image": upload.image.base64EncodedString(), "context": upload.context],
                                         credential: c, timings: &timings)
        let answer = try ClaudePrompt.parse(String(decoding: data, as: UTF8.self))
        var why = ["sent \(upload.summary) to BetterAirdrop's hosted naming (Claude, "
                   + (c.isTrial ? "free trial)" : "with this Mac's Pro license)")]
        if let remaining {
            why.append(c.isTrial ? "\(remaining) free trial name\(remaining == 1 ? "" : "s") left"
                                 : "\(remaining) hosted name\(remaining == 1 ? "" : "s") left this month")
        }
        return upload.suggestion(answer, context: ctx, backend: id, why: why, timings: timings, usage: nil)
    }

    /// A PDF: `POST /v1/name-text` with the extracted text and a few facts about the PDF. No file,
    /// no image. It counts against the same monthly names and daily cap as photos.
    func suggestDocument(_ doc: DocumentText, credential c: Credential, timings: inout StageTimings) throws -> NameSuggestion {
        let (data, remaining) = try call("v1/name-text", ["context": DocumentPrompt.context(doc), "text": doc.text],
                                         credential: c, timings: &timings)
        let answer = try DocumentPrompt.parse(String(decoding: data, as: UTF8.self))
        var s = answer.suggestion(backend: id, maxWords: 6, source: "Claude", now: now())
        var why = ["sent \(doc.text.count) characters of the PDF's text (no file or image) to BetterAirdrop's hosted naming (Claude, with this Mac's Pro license)"]
        if let remaining { why.append("\(remaining) hosted name\(remaining == 1 ? "" : "s") left this month") }
        s.why = why + s.why
        s.timings = timings
        return s
    }

    /// One logical request, with a retry for network errors and 500/502/504. Returns the 200 body
    /// and the names left this month (for the trial: trial names left). The trial's own count goes to
    /// `trial`, never to `usage` (which is the Pro license's month).
    func call(_ path: String, _ body: [String: String], credential c: Credential, timings: inout StageTimings) throws -> (Data, Int?) {
        let usage = c.isTrial ? UsageBox() : Self.usage
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(c.authorization, forHTTPHeaderField: "authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            attempt += 1
            let response: HTTPURLResponse, data: Data
            do {
                (response, data) = try timings.time(.hosted) { try transport.send(req) }
            } catch {
                if attempt < maxAttempts { timings.time(.hosted) { sleep(CloudUpload.backoff(attempt, retryAfter: nil)) }; continue }
                let failure = Error.network((error as NSError).localizedDescription)
                usage.record(error: failure.description, now: now())
                throw failure
            }
            let status = response.statusCode
            if status == 200, c.isTrial {
                let remaining = response.value(forHTTPHeaderField: "x-trial-remaining").flatMap { Int($0) }
                if let remaining { trial?.record(remaining: remaining) }
                return (data, remaining)
            }
            if status == 200 {
                let remaining = response.value(forHTTPHeaderField: "x-names-remaining").flatMap { Int($0) }
                let resets = response.value(forHTTPHeaderField: "x-names-reset").flatMap { ISO8601DateFormatter().date(from: $0) }
                Self.usage.record(remaining: remaining, resets: resets, error: nil, now: now())
                return (data, remaining)
            }
            let (type, message, resets) = Self.errorBody(data)
            let failure: Error
            switch status {
            case 403 where type == "trial_used_up": failure = .trialUsedUp; trial?.markUsedUp()
            case 403 where type == "trial_photos_only": failure = .noLicense
            case 401, 403: failure = .licenseInvalid
            case 429 where type == "trial_daily_limit": failure = .trialDailyLimit(resets: resets)
            case 429: failure = type == "daily_limit" ? .dailyLimit(resets: resets) : .monthlyLimit(resets: resets)
            case 422 where type == "refusal": failure = .refusal
            case 503: failure = .unavailable(message)
            case 500, 504, 502 where type != "bad_output":
                if attempt < maxAttempts { timings.time(.hosted) { sleep(CloudUpload.backoff(attempt, retryAfter: nil)) }; continue }
                failure = .http(status, message)
            default: failure = .http(status, message)
            }
            Self.blocks.record(failure, key: c.block)
            if case .monthlyLimit(let d) = failure {
                usage.record(remaining: 0, resets: d, error: failure.description, now: now())
            } else {
                usage.record(error: failure.description, now: now())
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
        /// This key's limit until it resets: the license's month, or the trial's day.
        private var limited: (key: String, until: Date, error: Error)?
        private var daily: Date?

        func reason(key: String, now: Date) -> Error? {
            lock.lock(); defer { lock.unlock() }
            if invalidKey == key { return .licenseInvalid }
            if let m = limited, m.key == key, now < m.until { return m.error }
            if let d = daily, now < d, !key.hasPrefix("trial:") { return .dailyLimit(resets: d) }
            return nil
        }

        func record(_ e: Error, key: String) {
            lock.lock(); defer { lock.unlock() }
            switch e {
            case .licenseInvalid: invalidKey = key
            case .monthlyLimit(let d?), .trialDailyLimit(let d?): limited = (key, d, e)
            case .dailyLimit(let d?): daily = d
            default: break
            }
        }

        func reset() {
            lock.lock(); invalidKey = nil; limited = nil; daily = nil; lock.unlock()
        }
    }
}
