@testable import BetterAirdropCore
import Foundation
import Testing

/// The free Pro naming trial. In `HostedNamerTests` (serialized) because it shares HostedStubProtocol
/// and HostedNamer's process-wide blocks.
extension HostedNamerTests {
    func trialNamer(_ store: TrialStore, clock: Clock = Clock()) -> HostedNamer {
        var n = namer(nil, clock: clock)
        n.trial = store
        return n
    }

    static func trialReply(_ remaining: Int) -> HostedStubProtocol.Reply {
        .init(status: 200, body: goodAnswer, headers: ["x-trial-remaining": "\(remaining)"])
    }

    @Test func trialSendsTheInstallIDAndCountsDown() throws {
        let store = TrialStore(directory: dir.path("trial-\(UUID().uuidString)"))
        #expect(store.read() == nil, "no file until the first trial request")
        HostedStubProtocol.reset([Self.trialReply(24), Self.trialReply(23)])
        let (url, ctx) = photo()
        let n = trialNamer(store)
        let s = try n.suggest(for: url, context: ctx)
        #expect(s.backend == "hosted" && s.why.contains("24 free trial names left"))
        let id = try #require(store.read()?.id)
        #expect(UUID(uuidString: id) != nil)
        #expect(HostedStubProtocol.captured.first?.0.value(forHTTPHeaderField: "authorization") == "Trial \(id)")
        _ = try n.suggest(for: url, context: ctx)
        #expect(HostedStubProtocol.captured.last?.0.value(forHTTPHeaderField: "authorization") == "Trial \(id)", "the same ID each time")
        #expect(store.read() == TrialState(id: id, remaining: 23, usedUp: false))
        #expect(HostedNamer.lastUsage() == nil, "the trial's count isn't the Pro license's month")
    }

    /// The 25th name ends the trial without another request; after it, photos go to the free engine.
    @Test func trialCapThenFallback() throws {
        let store = TrialStore(directory: dir.path("trial-\(UUID().uuidString)"))
        HostedStubProtocol.reset([Self.trialReply(0)])
        let (url, ctx) = photo()
        let n = trialNamer(store)
        _ = try n.suggest(for: url, context: ctx)
        #expect(store.isUsedUp)
        #expect(n.availability() == .unavailable(HostedNamer.Error.trialUsedUp.description))
        let s = try FallbackNamer(primary: n, fallback: VisionNamer()).suggest(for: url, context: ctx)
        #expect(s.backend == "vision" && s.fallbackFrom?.contains("free Pro naming trial is used up") == true)
        #expect(HostedStubProtocol.captured.count == 1, "no request once it's used up")

        // A rebuilt engine (the app rebuilds when the trial ends) is the free one, with no hosted step.
        var trialOn = Config(); trialOn.proTrial = true
        #expect(try Backends.resolve("auto", config: trialOn, auth: .none, apple: Self.apple(false), trial: store) is VisionNamer)
        #expect(try Backends.resolve("auto", config: trialOn, auth: .none, apple: Self.apple(true), trial: store).id == "apple")
    }

    @Test func serverSaysUsedUp() throws {
        let store = TrialStore(directory: dir.path("trial-\(UUID().uuidString)"))
        HostedStubProtocol.reset([.init(status: 403, body: hostedError("trial_used_up", "used up"))])
        let (url, ctx) = photo()
        let n = trialNamer(store)
        #expect(throws: HostedNamer.Error.trialUsedUp) { try n.suggest(for: url, context: ctx) }
        #expect(store.read()?.usedUp == true && store.read()?.remaining == 0)
        #expect(throws: HostedNamer.Error.trialUsedUp) { try n.suggest(for: url, context: ctx) }
        #expect(HostedStubProtocol.captured.count == 1)
    }

    /// The trial's daily cap holds trial photos until the reset, and never blocks a Pro license (or the reverse).
    @Test func trialDailyCap() throws {
        let store = TrialStore(directory: dir.path("trial-\(UUID().uuidString)"))
        HostedStubProtocol.reset([.init(status: 429, body: hostedError("trial_daily_limit", "busy", resets: "2026-10-16T00:00:00Z"))])
        let (url, ctx) = photo()
        let clock = Clock()
        let n = trialNamer(store, clock: clock)
        let resets = try #require(ISO8601DateFormatter().date(from: "2026-10-16T00:00:00Z"))
        #expect(throws: HostedNamer.Error.trialDailyLimit(resets: resets)) { try n.suggest(for: url, context: ctx) }
        #expect(!store.isUsedUp, "a busy day doesn't end the trial")
        #expect(n.availability() == .unavailable(HostedNamer.Error.trialDailyLimit(resets: resets).description))
        #expect(HostedNamer.currentTrialProblem(id: store.read()?.id, now: clock.now)?.hasPrefix("the free Pro naming trial reached today's limit") == true)
        var pro = n
        pro.license = FixedLicense(key: Self.key)
        #expect(pro.availability() == .ready, "Pro isn't held by the trial's limit")
        clock.now = resets.addingTimeInterval(1)
        #expect(n.availability() == .ready)

        HostedNamer.blocks.record(.dailyLimit(resets: resets.addingTimeInterval(86_400)), key: Self.key)
        #expect(n.availability() == .ready, "the trial isn't held by the paid daily limit")
    }

    @Test func trialNamesPhotosOnly() throws {
        let store = TrialStore(directory: dir.path("trial-\(UUID().uuidString)"))
        HostedStubProtocol.reset([Self.trialReply(24)])
        let (url, base) = photo()
        var ctx = base
        ctx.document = DocumentText(text: "INVOICE Bell Canada", source: .text, pages: 1)
        #expect(throws: HostedNamer.Error.noLicense) { try trialNamer(store).suggest(for: url, context: ctx) }
        #expect(HostedStubProtocol.captured.isEmpty)
        var on = Config(); on.proTrial = true
        #expect(Backends.resolveDocuments("auto", config: on, auth: .none, apple: Self.apple(false)) == nil, "no PDF engine from the trial")
    }

    /// Where the trial sits in `auto`, and every way it stays off.
    @Test func trialEngineOrderAndOptOut() throws {
        HostedNamer.blocks.reset()
        let store = TrialStore(directory: dir.path("trial-\(UUID().uuidString)"))
        let key = ClaudeAuth(environment: ["ANTHROPIC_API_KEY": "sk-ant-x"], storedKey: { nil }, antPath: { nil })
        var on = Config(); on.proTrial = true
        func auto(_ config: Config, _ auth: ClaudeAuth = .none, license: FixedLicense = FixedLicense(key: nil), apple: Bool = true) throws -> any Namer {
            try Backends.resolve("auto", config: config, auth: auth, apple: Self.apple(apple), license: license, trial: store)
        }
        let trial = try auto(on)
        #expect(trial.id == "hosted" && (trial as? FallbackNamer)?.fallback.id == "apple")
        #expect(((trial as? FallbackNamer)?.primary as? HostedNamer)?.trial != nil)
        #expect(try auto(on, apple: false).id == "hosted")
        #expect(try auto(on, key).id == "claude", "your own key comes first")
        let pro = try auto(on, license: FixedLicense(key: Self.key))
        #expect(((pro as? FallbackNamer)?.primary as? HostedNamer)?.trial == nil, "Pro uses the license, not the trial")

        // Off by default, and off for anyone who turns it off: exactly the free engines.
        #expect(Config().proTrial == false)
        #expect(try auto(Config()).id == "apple")
        #expect(try auto(Config(), apple: false) is VisionNamer)
        var local = on; local.claudeInAuto = false
        #expect(try auto(local).id == "apple", "claude.auto = false keeps auto on this Mac")
        for backend in ["vision", "apple"] {
            #expect(try Backends.resolve(backend, config: on, auth: .none, apple: Self.apple(true), trial: store).id == backend)
        }
        #expect(try Backends.resolve("auto", config: on, auth: .none, apple: Self.apple(true)).id == "apple", "no store passed: no trial")
        #expect(store.read() == nil, "resolving never makes a trial ID")
    }

    @Test func trialConfigKey() throws {
        #expect(try Config.parse("pro_trial = true\n").proTrial)
        #expect(throws: Config.ParseError.self) { try Config.parse("pro_trial = \"yes\"\n") }
        var c = Config(); c.proTrial = true
        #expect(c.rendered(updating: nil).contains("pro_trial = true"))
        #expect(!Config().rendered(updating: nil).contains("pro_trial"), "the default isn't written")
        #expect(try Config.parse(c.rendered(updating: "# mine\npro_trial = false # keep\n")) == c)
    }
}
