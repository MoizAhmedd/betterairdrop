import Foundation

/// The free Pro naming trial on this Mac, as last heard from the server.
public struct TrialState: Codable, Equatable, Sendable {
    /// A random UUID for this install. The Worker counts the trial's names per ID; it's not tied to
    /// the user, the Mac or anything else.
    public var id: String
    /// Trial names left, as the server last said. Nil before the first one.
    public var remaining: Int?
    /// The server said they're used up (or the last one was just used): no more trial requests.
    public var usedUp = false

    enum CodingKeys: String, CodingKey { case id, remaining, usedUp = "used_up" }
}

/// `~/Library/Application Support/betterairdrop/pro-trial.json`. Only used while `pro_trial` is on
/// (Backends.resolve); the file is made with the first trial request, never before.
public struct TrialStore: Sendable {
    /// What the server gives each install (TRIAL_CAP in hosted/wrangler.jsonc), for the app's copy.
    public static let names = 25

    public let directory: URL
    public var file: URL { directory.appendingPathComponent("pro-trial.json") }

    public init(directory: URL = Paths.supportDirectory) { self.directory = directory }

    public func read() -> TrialState? {
        FileManager.default.contents(atPath: file.path).flatMap { try? JSONDecoder().decode(TrialState.self, from: $0) }
    }

    public var isUsedUp: Bool { read()?.usedUp == true }

    /// The ID to send, made and saved the first time. Nil once the trial is used up.
    func activeID() -> String? {
        if let s = read() { return s.usedUp ? nil : s.id }
        let s = TrialState(id: UUID().uuidString.lowercased())
        return write(s) ? s.id : nil
    }

    /// The server's count after a name. The last one ends the trial without another request.
    func record(remaining: Int) {
        guard var s = read() else { return }
        s.remaining = remaining
        s.usedUp = remaining <= 0
        write(s)
    }

    func markUsedUp() {
        guard var s = read() else { return }
        s.remaining = 0
        s.usedUp = true
        write(s)
    }

    @discardableResult
    private func write(_ s: TrialState) -> Bool {
        guard let data = try? JSONEncoder().encode(s) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil
    }
}
