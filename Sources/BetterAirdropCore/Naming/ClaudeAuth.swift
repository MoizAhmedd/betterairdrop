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

    private let lock = NSLock()
    private var cached: ClaudeCredential??

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                storedKey: @escaping @Sendable () -> String? = { CredentialStore().readAPIKey() },
                antPath: (@Sendable () -> String?)? = nil,
                runAnt: @escaping @Sendable (String, [String]) -> String? = { ClaudeAuth.run($0, $1) }) {
        self.environment = environment
        self.storedKey = storedKey
        let env = environment
        self.antPath = antPath ?? { ClaudeAuth.findExecutable("ant", environment: env) }
        self.runAnt = runAnt
    }

    /// A resolver that never finds anything (tests, and `backend = "vision"`).
    public static let none = ClaudeAuth(environment: [:], storedKey: { nil }, antPath: { nil }, runAnt: { _, _ in nil })

    public func resolve() -> ClaudeCredential? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let start = DispatchTime.now().uptimeNanoseconds
        let c = lookup()
        _lastLookupMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        cached = .some(c)
        return c
    }

    private var _lastLookupMilliseconds: Int?
    /// How long the last uncached lookup took (spawning `ant` dominates), for `explain`.
    public var lastLookupMilliseconds: Int? { lock.lock(); defer { lock.unlock() }; return _lastLookupMilliseconds }

    /// Forgets the cached credential (after a 401, so an expired OAuth token is refreshed once).
    public func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    func lookup() -> ClaudeCredential? {
        if let k = environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return .apiKey(k, source: .environment)
        }
        if let k = storedKey() { return .apiKey(k, source: .stored) }
        if let token = antToken() { return .oauth(token) }
        return nil
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

    public var antInstalled: Bool { antPath() != nil }
    public var antExecutable: String? { antPath() }

    /// What each source looks like right now, without revealing any secret.
    public func report() -> [(Source, String)] {
        var rows: [(Source, String)] = []
        let env = environment["ANTHROPIC_API_KEY"].map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        rows.append((.environment, env ? "set" : "not set"))
        rows.append((.stored, storedKey() != nil ? "stored" : "none (run `betterairdrop auth claude`)"))
        if let ant = antPath() {
            rows.append((.antCLI, antToken() != nil ? "logged in (\(ant))" : "installed, not logged in (run `betterairdrop auth login`)"))
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
