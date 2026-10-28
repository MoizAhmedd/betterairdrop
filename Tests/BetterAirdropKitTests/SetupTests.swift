@testable import BetterAirdropCore
@testable import BetterAirdropKit
import Foundation
import Testing

private let key = "sk-ant-api03-abcdefghijklmnop"

private func context(_ config: Config = Config(), env: [String: String] = [:], stored: Bool = false, ant: Bool = false,
                     apple: String? = "requires macOS 27") -> SetupContext {
    SetupContext(config: config, environment: env, storedKey: stored, antLoggedIn: ant, appleUnavailable: apple)
}

private func error(_ r: SetupRequest, _ c: SetupContext) -> String? {
    do { _ = try SetupPlan.make(r, c); return nil } catch { return "\(error)" }
}

@Suite struct SetupPlanTests {
    @Test func engineIsValidatedAndApplied() throws {
        let p = try SetupPlan.make(SetupRequest(engine: "vision"), context())
        #expect(p.config.backend == "vision")
        #expect(p.changes == ["Naming engine: auto → vision"])
        #expect(p.keyToStore == nil)
        #expect(error(SetupRequest(engine: "gpt"), context()) == "--engine must be one of auto, apple, claude, vision")
    }

    @Test func nothingRequestedChangesNothing() throws {
        var c = Config(); c.backend = "claude"; c.watchNotify = false
        let p = try SetupPlan.make(SetupRequest(), context(c, stored: true))
        #expect(p.config == c)
        #expect(p.changes.isEmpty)
        #expect(p.launchAtLogin == nil)
    }

    @Test func keyFromAnEnvironmentVariable() throws {
        let p = try SetupPlan.make(SetupRequest(engine: "claude", apiKeyEnv: "MY_KEY"), context(env: ["MY_KEY": " \(key)\n"]))
        #expect(p.keyToStore == key)
        #expect(p.config.backend == "claude")
        #expect(p.changes.contains("Claude key: store $MY_KEY (…mnop)"))
        #expect(!p.changes.joined().contains(key))   // never printed
    }

    @Test func keyProblems() {
        #expect(error(SetupRequest(apiKeyEnv: "MY_KEY"), context()) == "$MY_KEY isn't set in this shell")
        #expect(error(SetupRequest(apiKeyEnv: "MY_KEY"), context(env: ["MY_KEY": ""])) == "$MY_KEY isn't set in this shell")
        #expect(error(SetupRequest(apiKeyEnv: "K"), context(env: ["K": "hunter2"]))?.contains("start with sk-ant-") == true)
        #expect(error(SetupRequest(apiKeyFromStdin: "sk-ant- with spaces"), context())?.contains("start with sk-ant-") == true)
        #expect(error(SetupRequest(apiKeyFromStdin: "\n"), context()) == "no key on standard input")
        #expect(error(SetupRequest(apiKeyEnv: "K", apiKeyFromStdin: key), context(env: ["K": key])) == "pass --api-key-env or --api-key-stdin, not both")
        #expect(try! SetupPlan.make(SetupRequest(apiKeyFromStdin: key + "\n"), context()).keyToStore == key)
    }

    @Test func claudeNeedsACredentialTheAppCanUse() throws {
        // The app never sees the shell's environment, so ANTHROPIC_API_KEY alone isn't enough.
        let e = error(SetupRequest(engine: "claude"), context(env: ["ANTHROPIC_API_KEY": key]))
        #expect(e?.contains("add --api-key-env ANTHROPIC_API_KEY") == true)
        #expect(error(SetupRequest(engine: "claude"), context())?.contains("ant auth login") == true)
        #expect(try SetupPlan.make(SetupRequest(engine: "claude"), context(stored: true)).config.backend == "claude")
        #expect(try SetupPlan.make(SetupRequest(engine: "claude"), context(ant: true)).config.backend == "claude")
    }

    @Test func autoWithoutAKeyNotesVision() throws {
        let p = try SetupPlan.make(SetupRequest(engine: "auto"), context(env: ["ANTHROPIC_API_KEY": key]))
        #expect(p.notes.count == 1)
        #expect(p.notes[0].hasPrefix("Photos will be named with Apple Vision"))
        #expect(p.notes[0].contains("--api-key-env ANTHROPIC_API_KEY"))
        #expect(try SetupPlan.make(SetupRequest(engine: "auto"), context(stored: true)).notes.isEmpty)
        #expect(try SetupPlan.make(SetupRequest(engine: "vision"), context()).notes.isEmpty)
        #expect(try SetupPlan.make(SetupRequest(engine: "auto"), context(apple: nil)).notes.isEmpty)   // auto uses Apple Intelligence
    }

    @Test func appleOnlyWhenReady() throws {
        #expect(error(SetupRequest(engine: "apple"), context())?.contains("Use --engine auto") == true)
        #expect(try SetupPlan.make(SetupRequest(engine: "apple"), context(apple: nil)).config.backend == "apple")
    }

    @Test func notifyAndLoginItem() throws {
        let p = try SetupPlan.make(SetupRequest(launchAtLogin: false, notify: false), context())
        #expect(p.config.watchNotify == false)
        #expect(p.launchAtLogin == false)
        #expect(p.changes == ["Notifications after each batch: off", "Open at login: off"])
        // Already on: no change line for notifications.
        #expect(try SetupPlan.make(SetupRequest(notify: true), context()).changes.isEmpty)
    }
}

@Suite struct FirstRunPlanTests {
    @Test func onlyOnce() {
        #expect(FirstRunPlan.make(onboardingDone: true, setup: nil, notify: true) == nil)
        #expect(FirstRunPlan.make(onboardingDone: true, setup: SetupRecord(), notify: true) == nil)
    }

    @Test func withoutSetupItsTheZeroWizardFirstRun() {
        let p = FirstRunPlan.make(onboardingDone: false, setup: nil, notify: true)
        #expect(p == FirstRunPlan(lookForShellKey: true, registerLoginItem: true, askNotificationsAfterAccess: false))
    }

    @Test func afterSetupOnlyThePermissionsAreLeft() {
        let p = FirstRunPlan.make(onboardingDone: false, setup: SetupRecord(launchAtLogin: nil), notify: true)
        #expect(p == FirstRunPlan(lookForShellKey: false, registerLoginItem: true, askNotificationsAfterAccess: true))
        #expect(FirstRunPlan.make(onboardingDone: false, setup: SetupRecord(launchAtLogin: false), notify: true)?.registerLoginItem == false)
        #expect(FirstRunPlan.make(onboardingDone: false, setup: SetupRecord(), notify: false)?.askNotificationsAfterAccess == false)
    }
}

@Suite struct SetupRecordTests {
    @Test func roundTripsWithSnakeCaseKeys() throws {
        let t = Temp()
        let url = t.url.appendingPathComponent("sub/setup.json")
        #expect(SetupRecord.load(from: url) == nil)
        let r = SetupRecord(completedAt: Date(timeIntervalSince1970: 1_800_000_000), launchAtLogin: true)
        try r.save(to: url)
        #expect(SetupRecord.load(from: url) == r)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"completed_at\" : \"2027-01-15T08:00:00Z\""))
        #expect(text.contains("\"launch_at_login\" : true"))
        try Data("not json".utf8).write(to: url)
        #expect(SetupRecord.load(from: url) == nil)
    }
}

@Suite struct StatusReportTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func state(_ access: AppState.Access = .granted, _ notes: AppState.Notifications = .allowed,
               login: AppState.LoginItem = .enabled, watch: AppState.Watch = .watching) -> AppState {
        AppState(version: "0.4.0", pid: 42, updatedAt: t0, folder: "~/Downloads", folderAccess: access,
                 notifications: notes, loginItem: login, watch: watch)
    }

    func inputs(app: String? = "/Users/me/Applications/BetterAirdrop.app", running: Bool = true, state: AppState? = nil,
                setup: SetupRecord? = SetupRecord(), config: Config = Config(), stored: Bool = true,
                holder: ProcessLock.Owner? = nil) -> StatusReport.Inputs {
        StatusReport.Inputs(cliVersion: "0.4.0", appPath: app, appVersion: app == nil ? nil : "0.4.0", appRunning: running,
                            appState: state, setup: setup, config: config, storedKey: stored, antLoggedIn: false, lockHolder: holder)
    }

    @Test func readyWhenTheAppIsWatching() throws {
        let r = StatusReport.make(inputs(state: state()))
        #expect(r.ready)
        #expect(r.nextSteps.isEmpty)
        #expect(r.watching == .init(state: "watching", folder: "~/Downloads", by: "app"))
        #expect(r.permissions.folderAccess == "granted")
        #expect(r.engine.active.hasPrefix("Claude"))
        #expect(r.credentials.claude == .init(present: true, source: "stored"))
    }

    @Test func jsonShape() throws {
        let json = try StatusReport.make(inputs(state: state(.waiting, .notAsked, watch: .starting))).json()
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(Set(obj.keys) == ["schema", "ready", "cli_version", "app", "setup", "engine", "credentials", "permissions", "watching", "next_steps"])
        let p = obj["permissions"] as! [String: Any]
        #expect(Set(p.keys) == ["folder_access", "notifications", "login_item", "reported_at"])
        #expect(p["reported_at"] as? String == "2027-01-15T08:00:00Z")
        let steps = obj["next_steps"] as! [[String: Any]]
        #expect(steps.first?["who"] as? String == "human")
        #expect(steps.first?["required"] as? Bool == true)
        #expect(((obj["credentials"] as! [String: Any])["claude"] as! [String: Any])["source"] as? String == "stored")
        #expect(obj["schema"] as? Int == 1)
    }

    @Test func waitingForThePeopleClicks() {
        let r = StatusReport.make(inputs(state: state(.waiting, .notAsked, watch: .starting)))
        #expect(!r.ready)
        #expect(r.nextSteps.map(\.who) == ["human", "human"])
        #expect(r.nextSteps[0].text.contains("access files in your Downloads folder"))
        #expect(r.nextSteps[0].required)
        #expect(r.nextSteps[1].text.contains("send notifications"))
        #expect(!r.nextSteps[1].required)
        // Without setup the notifications prompt waits for the first rename, so it isn't a step yet.
        #expect(StatusReport.make(inputs(state: state(.granted, .notAsked), setup: nil)).nextSteps.isEmpty)
    }

    @Test func refusedPermissionsPointAtSystemSettings() {
        let r = StatusReport.make(inputs(state: state(.denied, .denied, login: .requiresApproval, watch: .noAccess)))
        #expect(!r.ready)
        #expect(r.nextSteps.compactMap(\.command) == [StatusReport.privacyFilesPane, StatusReport.notificationsPane, StatusReport.loginItemsPane])
        #expect(r.nextSteps.map(\.required) == [true, false, false])
        // Notifications switched off in the config: no step about them.
        var c = Config(); c.watchNotify = false
        #expect(StatusReport.make(inputs(state: state(.granted, .denied), config: c)).nextSteps.isEmpty)
    }

    @Test func notInstalledOrNotRunning() {
        let none = StatusReport.make(inputs(app: nil, running: false, setup: nil))
        #expect(!none.app.installed && !none.ready)
        #expect(none.nextSteps.map(\.who) == ["agent"])
        #expect(none.nextSteps[0].command?.contains("/install | sh") == true)
        #expect(none.permissions.folderAccess == "unknown")

        // Stopped app: its last report is kept for permissions, but nothing is watching.
        let stopped = StatusReport.make(inputs(running: false, state: state()))
        #expect(stopped.watching.state == "not_running")
        #expect(stopped.permissions.folderAccess == "granted")
        #expect(stopped.nextSteps.first?.command == "open '/Users/me/Applications/BetterAirdrop.app'")

        // Running, but too old to write app-state.json.
        let old = StatusReport.make(inputs(running: true, state: nil))
        #expect(old.watching.state == "unknown" && !old.ready)
        #expect(StatusReport.make(inputs(running: true, state: nil, holder: .init(kind: .app, folder: "/x"))).ready)
    }

    @Test func aTerminalWatcherCounts() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let h = ProcessLock.Owner(kind: .cli, pid: 777, folder: home + "/Downloads")
        let r = StatusReport.make(inputs(state: state(watch: .standingBy), holder: h))
        #expect(r.ready)
        #expect(r.watching == .init(state: "watching", folder: "~/Downloads", by: "cli"))
        #expect(r.nextSteps.contains { $0.who == "agent" && $0.text.contains("pid 777") })
    }

    @Test func pausedNeedsAPerson() {
        let r = StatusReport.make(inputs(state: state(watch: .paused)))
        #expect(!r.ready)
        #expect(r.nextSteps.map(\.text) == ["Resume from the BetterAirdrop menu-bar icon (it's paused)."])
    }

    @Test func noKeyIsAnOptionalAgentStep() {
        let r = StatusReport.make(inputs(state: state(), stored: false))
        #expect(r.ready)
        #expect(r.engine.active == "Apple Vision")
        #expect(r.nextSteps.map(\.who) == ["agent"])
        #expect(r.nextSteps[0].required == false)
        var c = Config(); c.backend = "vision"
        #expect(StatusReport.make(inputs(state: state(), config: c, stored: false)).nextSteps.isEmpty)   // chose Vision
        // With Apple Intelligence ready, auto names on-device without a key: no nudge.
        var i = inputs(state: state(), stored: false)
        i.appleReady = true
        let r2 = StatusReport.make(i)
        #expect(r2.engine.active == "Apple Intelligence")
        #expect(r2.nextSteps.isEmpty)
    }

    /// An expired `ant` login (or a rejected key) is a "Needs you" step with the fix, and the engine
    /// is what names photos meanwhile: hosted with Pro, else on this Mac.
    @Test func rejectedClaudeCredentialNeedsYou() throws {
        let p = ClaudeAuth.Problem(kind: .antLogin, detail: ClaudeAuth.Problem.antExpired)
        var i = inputs(state: state(), stored: false)
        i.antLoggedIn = true
        i.claudeProblem = p
        let r = StatusReport.make(i)
        #expect(r.engine.active == "Apple Vision")
        #expect(r.engine.detail == p.message)
        #expect(r.credentials.claude == .init(present: true, source: "ant", problem: p.message))
        #expect(r.nextSteps.count == 1)
        let step = try #require(r.nextSteps.first)
        #expect(step.who == "human" && step.required && step.command == "ant auth login")
        #expect(step.text == "Claude login expired. Run `ant auth login` in Terminal. Until then, photos are named on this Mac with Apple Vision.")
        #expect(!step.text.contains("—"))

        i.license = License(key: "BA_1234ABCD-5678-EF90", activationID: "a", label: "Mac", activatedAt: t0)
        i.now = t0
        let pro = StatusReport.make(i)
        #expect(pro.engine.active == EngineStatus.hostedName)
        #expect(pro.nextSteps.last?.text.hasSuffix("Until then, Pro naming names your photos.") == true)

        // It round-trips through app-state.json, and `problem` is always in the JSON.
        var s = state(); s.claude = p
        let t = Temp(), url = t.url.appendingPathComponent("app-state.json")
        try s.save(to: url)
        #expect(AppState.load(from: url)?.claude == p)
        let json = try StatusReport.make(inputs(state: state())).json()
        #expect(json.contains("\"problem\" : null"))
    }

    @Test func appStateRoundTrip() throws {
        let t = Temp()
        let url = t.url.appendingPathComponent("app-state.json")
        try state(.denied, .notAsked, login: .disabled, watch: .noAccess).save(to: url)
        #expect(AppState.load(from: url) == state(.denied, .notAsked, login: .disabled, watch: .noAccess))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"folder_access\" : \"denied\""))
        #expect(text.contains("\"watch\" : \"no_access\""))
        #expect(text.contains("\"notifications\" : \"not_asked\""))
    }

    @Test func tilde() {
        #expect(StatusReport.tilde("/Users/me/Downloads", home: "/Users/me") == "~/Downloads")
        #expect(StatusReport.tilde("/Users/meme/Downloads", home: "/Users/me") == "/Users/meme/Downloads")
    }
}
