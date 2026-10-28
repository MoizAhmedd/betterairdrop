import Foundation

/// A credential for the Anthropic API. Exactly one kind of auth header is ever sent.
public enum ClaudeCredential: Sendable, Equatable {
    /// `x-api-key`, from `ANTHROPIC_API_KEY` or the stored key file.
    case apiKey(String, source: ClaudeAuth.Source)
    /// `Authorization: Bearer` + `anthropic-beta: oauth-2025-04-20`, from the Anthropic CLI (`ant`).
    case oauth(String)

    public var source: ClaudeAuth.Source {
        switch self {
        case .apiKey(_, let s): s
        case .oauth: .antCLI
        }
    }

    /// The auth headers for a request. Never both kinds.
    public var headers: [String: String] {
        switch self {
        case .apiKey(let k, _): ["x-api-key": k]
        case .oauth(let t): ["authorization": "Bearer \(t)", "anthropic-beta": "oauth-2025-04-20"]
        }
    }
}

/// Finds a credential, in this order (documented in the README):
///   1. `ANTHROPIC_API_KEY` in the environment
///   2. the key stored by `betterairdrop auth claude` or the app (`CredentialStore`, a 0600 file)
///   3. the Anthropic CLI's OAuth login: `ant auth print-credentials --access-token`
///
/// The result is cached in memory for this process only. Secrets are never logged or written.
/// An `ant` token is cached until 5 minutes before the expiry `ant` reports (5 minutes if it doesn't
/// say), so a long-running app refreshes it before it lapses instead of after a failed request.
public final class ClaudeAuth: @unchecked Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case environment = "ANTHROPIC_API_KEY"
        case stored = "Stored key (betterairdrop auth claude)"
        case antCLI = "Anthropic CLI login (ant)"
    }

    public static let shared = ClaudeAuth()

    let environment: [String: String]
    let storedKey: @Sendable () -> String?
    let antPath: @Sendable () -> String?
    let runAnt: @Sendable (String, [String]) -> String?
    let now: @Sendable () -> Date
    /// When `ant` last wrote its login (`antCredentialsModified`), so `ant auth login` ends a backoff at once.
    let antStamp: @Sendable () -> Date?

    private let lock = NSLock()
    private var cached: (credential: ClaudeCredential?, validUntil: Date?)?
    /// The last auth failure, until a request succeeds or the credential changes.
    private var problem: Problem?
    /// Claude is skipped until then (unless the credential changes first).
    private var retryAt: Date?
    /// `stampLocked()` at the failure.
    private var problemStamp: Int?

    /// How long an `ant` token (or a failed lookup) is trusted when `ant` doesn't give an expiry.
    static let defaultTTL: TimeInterval = 300
    /// Refresh this long before the reported expiry.
    static let expiryMargin: TimeInterval = 300
    /// After an auth failure, Claude is skipped this long before it's tried again.
    static let retryInterval: TimeInterval = 600

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                storedKey: @escaping @Sendable () -> String? = { CredentialStore().readAPIKey() },
                antPath: (@Sendable () -> String?)? = nil,
                runAnt: @escaping @Sendable (String, [String]) -> String? = { ClaudeAuth.run($0, $1) },
                now: @escaping @Sendable () -> Date = { Date() },
                antStamp: @escaping @Sendable () -> Date? = { ClaudeAuth.antCredentialsModified() }) {
        self.environment = environment
        self.now = now
        self.antStamp = antStamp
        self.storedKey = storedKey
        let env = environment
        self.antPath = antPath ?? { ClaudeAuth.findExecutable("ant", environment: env) }
        self.runAnt = runAnt
    }

    /// A resolver that never finds anything (tests, and `backend = "vision"`).
    public static let none = ClaudeAuth(environment: [:], storedKey: { nil }, antPath: { nil }, runAnt: { _, _ in nil }, antStamp: { nil })

    public func resolve() -> ClaudeCredential? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.validUntil.map({ now() < $0 }) ?? true { return c.credential }
        let start = DispatchTime.now().uptimeNanoseconds
        let (c, validUntil) = lookup()
        _lastLookupMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        cached = (c, validUntil)
        return c
    }

    private var _lastLookupMilliseconds: Int?
    /// How long the last uncached lookup took (spawning `ant` dominates), for `explain`.
    public var lastLookupMilliseconds: Int? { lock.lock(); defer { lock.unlock() }; return _lastLookupMilliseconds }

    /// Forgets the cached credential (after a 401, so an expired OAuth token is refreshed once).
    public func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    /// The credential and how long to trust it (nil = for the rest of the process: API keys).
    func lookup() -> (ClaudeCredential?, Date?) {
        if let k = environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return (.apiKey(k, source: .environment), nil)
        }
        if let k = storedKey() { return (.apiKey(k, source: .stored), nil) }
        let t = now()
        guard let (token, expiry) = antCredential() else { return (nil, t.addingTimeInterval(Self.defaultTTL)) }
        if let expiry, expiry <= t {
            // `ant` hands back the expired token when it couldn't refresh it (its refresh token
            // expired too). Back off now, with no 401 round trip, and don't run `ant` again until then.
            recordLocked(.antLogin, detail: Problem.antExpired)
            return (.oauth(token), retryAt)
        }
        let until = expiry.map { max($0.addingTimeInterval(-Self.expiryMargin), t.addingTimeInterval(60)) }
        return (.oauth(token), until ?? t.addingTimeInterval(Self.defaultTTL))
    }

    // MARK: - Auth failures and backoff

    /// Claude's credential stopped working: an `ant` login that expired, or a key Anthropic rejected.
    /// Written to `app-state.json` (field names are part of `status --json`'s contract).
    public struct Problem: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// The `ant` login expired or was rejected.
            case antLogin = "ant_login"
            /// The key stored by `betterairdrop auth claude` (or the app) was rejected.
            case storedKey = "stored_key"
            /// `ANTHROPIC_API_KEY` was rejected.
            case environmentKey = "environment_key"
        }
        public var kind: Kind
        /// What went wrong, kept in `app-state.json` (no secrets).
        public var detail: String

        public init(kind: Kind, detail: String) { self.kind = kind; self.detail = detail }

        /// `detail` when `ant` could only hand back an expired token.
        public static let antExpired = "ant's token expired and ant couldn't refresh it"

        /// The problem and its fix, in plain words.
        public var message: String {
            switch kind {
            case .antLogin: "Claude login expired. Run `ant auth login` in Terminal."
            case .storedKey: "Anthropic rejected your Claude key. Add a new one in Settings or with `betterairdrop auth claude`."
            case .environmentKey: "Anthropic rejected ANTHROPIC_API_KEY. Set a valid key."
            }
        }

        /// The command that fixes it, if there is one.
        public var command: String? {
            switch kind {
            case .antLogin: "ant auth login"
            case .storedKey: "betterairdrop auth claude"
            case .environmentKey: nil
            }
        }

        static func kind(for source: Source) -> Kind {
            switch source {
            case .environment: .environmentKey
            case .stored: .storedKey
            case .antCLI: .antLogin
            }
        }
    }

    /// Anthropic rejected `credential` (a 401). Claude is skipped for `retryInterval`, or until the
    /// credential changes, so a broken login doesn't cost a request (and an `ant` run) per photo.
    public func recordAuthFailure(_ credential: ClaudeCredential, detail: String) {
        lock.lock(); defer { lock.unlock() }
        recordLocked(Problem.kind(for: credential.source), detail: detail)
        cached = (credential, retryAt)   // no `ant` run until it's tried again
    }

    /// A request went through: any problem is over.
    public func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        problem = nil; retryAt = nil; problemStamp = nil
    }

    /// The current problem, until a request succeeds or the credential changes (`ant auth login`,
    /// a new key). Shown in the app and `status`, also while Claude is being tried again.
    public func currentProblem() -> Problem? {
        lock.lock(); defer { lock.unlock() }
        return checkStampLocked()
    }

    /// The problem while Claude is being skipped (`ClaudeNamer.availability`): until `retryAt`,
    /// unless the credential changed first. Nil = try Claude.
    public func blockingProblem() -> Problem? {
        lock.lock(); defer { lock.unlock() }
        guard let p = checkStampLocked(), let r = retryAt, now() < r else { return nil }
        return p
    }

    private func recordLocked(_ kind: Problem.Kind, detail: String) {
        let t = now()
        problem = Problem(kind: kind, detail: detail)
        retryAt = t.addingTimeInterval(Self.retryInterval)
        problemStamp = stampLocked()
    }

    /// A changed credential ends the problem (and drops the cached one), so it's tried at once.
    private func checkStampLocked() -> Problem? {
        guard let p = problem else { return nil }
        guard stampLocked() == problemStamp else {
            problem = nil; retryAt = nil; problemStamp = nil; cached = nil
            return nil
        }
        return p
    }

    /// A hash of what could change the credential: the env key, the stored key and `ant`'s login
    /// date. In memory only, never stored or logged. Cheap: no `ant` run.
    private func stampLocked() -> Int {
        var h = Hasher()
        h.combine(environment["ANTHROPIC_API_KEY"])
        h.combine(storedKey())
        h.combine(antStamp())
        return h.finalize()
    }

    /// The newest modification date in `ant`'s credentials folder (`~/.config/anthropic/credentials`),
    /// or of the folder itself. Reads file dates only, never the files.
    public static func antCredentialsModified() -> Date? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/anthropic/credentials")
        let fm = FileManager.default
        func modified(_ path: String) -> Date? { (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
        let children = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).map { modified(dir.appendingPathComponent($0).path) }
        return ([modified(dir.path)] + children).compactMap { $0 }.max()
    }

    /// One `ant` call: `print-credentials` without the flag prints JSON with `access_token` and
    /// `expires_at` (Unix seconds), refreshing the token first if it's near expiry. Falls back to
    /// `--access-token` (just the token, no expiry) if the JSON isn't there.
    func antCredential() -> (String, Date?)? {
        guard let ant = antPath() else { return nil }
        if let out = runAnt(ant, ["auth", "print-credentials"]),
           let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
           let token = (obj["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty, !token.contains(" ") {
            let expiry = (obj["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return (token, expiry)
        }
        return antToken().map { ($0, nil) }
    }

    /// `ant auth print-credentials --access-token` prints just the token. Without the flag it
    /// prints JSON, so the flag is always passed.
    public func antToken() -> String? {
        guard let ant = antPath(),
              let out = runAnt(ant, ["auth", "print-credentials", "--access-token"]) else { return nil }
        let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(" "), !token.hasPrefix("{"), !token.contains("\n") else { return nil }
        return token
    }

    public enum AntLogin: Equatable, Sendable { case none, loggedIn, expired }

    /// The `ant` login as `status` shows it, from one `ant` run: `expired` when `ant` could only
    /// give back a token past its expiry (it couldn't refresh it).
    public func antLogin() -> AntLogin {
        guard let (_, expiry) = antCredential() else { return .none }
        return expiry.map { $0 <= now() } == true ? .expired : .loggedIn
    }

    public var antInstalled: Bool { antPath() != nil }
    public var antExecutable: String? { antPath() }

    /// What each source looks like right now, without revealing any secret.
    public func report() -> [(Source, String)] {
        var rows: [(Source, String)] = []
        let env = environment["ANTHROPIC_API_KEY"].map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        rows.append((.environment, env ? "set" : "not set"))
        rows.append((.stored, storedKey() != nil ? "stored" : "none (run `betterairdrop auth claude`)"))
        if let ant = antPath() {
            switch antLogin() {
            case .loggedIn: rows.append((.antCLI, "logged in (\(ant))"))
            case .expired: rows.append((.antCLI, "login expired (run `ant auth login`)"))
            case .none: rows.append((.antCLI, "installed, not logged in (run `betterairdrop auth login`)"))
            }
        } else {
            rows.append((.antCLI, "not installed (brew install anthropics/tap/ant)"))
        }
        return rows
    }

    // MARK: - key validation

    public enum Validation: Equatable, Sendable {
        case valid
        /// The key was rejected (typo, revoked, wrong workspace).
        case rejected(String)
        /// Couldn't tell (offline, Anthropic down). The key may be fine.
        case unreachable(String)
    }

    /// Checks a key with `GET /v1/models`, which is free, so a typo shows up in onboarding rather
    /// than as silent Vision fallbacks later. Synchronous: call it off the main thread.
    public static func validate(key: String, transport: any HTTPTransport = URLSessionTransport()) -> Validation {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.hasPrefix("sk-ant-"), !k.contains(" ") else {
            return .rejected("That doesn't look like an Anthropic API key. They start with sk-ant-.")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        req.timeoutInterval = 15
        req.setValue(k, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (resp, _) = try transport.send(req)
            switch resp.statusCode {
            case 200..<300: return .valid
            case 401: return .rejected("Anthropic didn't accept this key. Check that you copied all of it.")
            case 403: return .rejected("This key isn't allowed to use the API. Check its workspace in the Claude Console.")
            default: return .unreachable("Anthropic answered with an error (\(resp.statusCode)). Try again in a minute.")
            }
        } catch {
            return .unreachable("Couldn't reach Anthropic. Check your internet connection.")
        }
    }

    // MARK: - process helpers

    /// Looks on PATH, then in Homebrew's usual prefixes (launchd agents get a minimal PATH).
    public static func findExecutable(_ name: String, environment: [String: String]) -> String? {
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs where !d.isEmpty {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Runs a command with a timeout and returns stdout, or nil on failure. stderr is discarded.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 15) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Read concurrently so a large output can't fill the pipe and stall the child.
        let box = DataBox()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { box.data = out.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        read.wait()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }

    final class DataBox: @unchecked Sendable { var data = Data() }
}
