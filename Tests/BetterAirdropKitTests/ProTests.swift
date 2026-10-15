@testable import BetterAirdropCore
@testable import BetterAirdropKit
import Foundation
import Testing

/// Polar, canned. Each call gets the action (`activate`, `validate`, `deactivate`) and the JSON body.
final class FakePolar: HTTPTransport, @unchecked Sendable {
    struct Call { var action: String; var body: [String: String]; var url: URL }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var respond: (String, [String: String]) throws -> (Int, String)

    init(_ respond: @escaping (String, [String: String]) throws -> (Int, String)) { self.respond = respond }

    func send(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let action = request.url!.lastPathComponent
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: String] ?? [:]
        lock.lock(); calls.append(Call(action: action, body: body, url: request.url!)); lock.unlock()
        let (status, json) = try respond(action, body)
        return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    static let activated = #"{"id":"act-1","license_key_id":"lk-1","label":"Test Mac","meta":{},"created_at":"2026-10-15T00:00:00Z","modified_at":null,"license_key":{"id":"lk-1","display_key":"****-ABCD","status":"granted","limit_activations":3}}"#
    static let validated = #"{"id":"lk-1","display_key":"****-ABCD","status":"granted","limit_activations":3,"activation":{"id":"act-1"}}"#
    static let notFound = #"{"error":"ResourceNotFound","detail":"License key not found."}"#
    static let limit = #"{"error":"NotPermitted","detail":"License key only supports 3 activations. Limit reached."}"#
    static let revoked = #"{"error":"NotPermitted","detail":"License key is revoked."}"#
}

final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ s: String = "2026-10-15T12:00:00Z") { now = at(s) }
    func advance(days: Double) { now = now.addingTimeInterval(days * 86_400) }
}

let realOrg = "11111111-2222-4333-8444-555555555555"

func client(_ polar: FakePolar, _ temp: Temp, _ clock: TestClock = TestClock(), org: String = realOrg) -> LicenseClient {
    LicenseClient(api: URL(string: "https://api.polar.test")!, organizationID: org, transport: polar,
                  store: LicenseStore(directory: temp.url.appendingPathComponent("support")), now: { clock.now })
}

@Suite struct LicenseClientTests {
    @Test func activateStoresKeyAndActivationAs0600() throws {
        let t = Temp(), polar = FakePolar { _, _ in (200, FakePolar.activated) }
        let c = client(polar, t)
        let l = try c.activate(key: "  BA_1234-ABCD \n", label: "Test Mac")
        #expect(l.activationID == "act-1" && l.key == "BA_1234-ABCD" && l.maskedKey == "****-ABCD")
        #expect(polar.calls.map(\.action) == ["activate"])
        #expect(polar.calls[0].url.absoluteString == "https://api.polar.test/v1/customer-portal/license-keys/activate")
        #expect(polar.calls[0].body == ["key": "BA_1234-ABCD", "organization_id": realOrg, "label": "Test Mac"])
        #expect(c.store.read() == l)
        let mode = try FileManager.default.attributesOfItem(atPath: c.store.file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(c.status == .active && c.status.isUnlocked)
    }

    @Test func unknownKeyIsInvalid() {
        let t = Temp(), c = client(FakePolar { _, _ in (404, FakePolar.notFound) }, t)
        #expect(throws: LicenseClient.Failure.invalidKey) { try c.activate(key: "BA_NOPE", label: "x") }
        #expect(c.store.read() == nil && c.status == .free)
    }

    @Test func activationLimitIsExplained() {
        let t = Temp(), c = client(FakePolar { _, _ in (403, FakePolar.limit) }, t)
        #expect(throws: LicenseClient.Failure.activationLimit("License key only supports 3 activations. Limit reached.")) {
            try c.activate(key: "BA_FULL", label: "x")
        }
        #expect(LicenseClient.Failure.activationLimit("d").description.contains("3 Macs"))
        #expect(c.store.read() == nil)
    }

    @Test func revokedKeyCannotBeActivated() {
        let t = Temp(), c = client(FakePolar { _, _ in (403, FakePolar.revoked) }, t)
        #expect(throws: LicenseClient.Failure.notPermitted("License key is revoked.")) { try c.activate(key: "BA_X", label: "x") }
    }

    @Test func offlineActivationFailsWithoutSaving() {
        let t = Temp(), c = client(FakePolar { _, _ in throw URLError(.notConnectedToInternet) }, t)
        #expect(throws: LicenseClient.Failure.self) { try c.activate(key: "BA_X", label: "x") }
        #expect(c.store.read() == nil)
    }

    @Test func placeholderOrganizationMeansNotOnSale() {
        let t = Temp(), polar = FakePolar { _, _ in (200, FakePolar.activated) }
        let c = client(polar, t, org: "POLAR_ORG_ID_TODO")
        #expect(throws: LicenseClient.Failure.notAvailable) { try c.activate(key: "BA_X", label: "x") }
        #expect(polar.calls.isEmpty)
        #expect(LicenseClient.Failure.notAvailable.description.contains("isn't on sale yet"))
    }

    @Test func theRealPolarValuesAreIn() throws {
        #expect(!Polar.organizationID.contains("TODO") && !Polar.checkoutURL.contains("TODO"))
        #expect(UUID(uuidString: Polar.organizationID) != nil)
        let url = try #require(URL(string: Polar.checkoutURL))
        #expect(url.scheme == "https" && url.host == "buy.polar.sh" && url.path.count > 1)
        #expect(Polar.isReal(organizationID: Polar.organizationID) && Polar.canBuy)
    }

    @Test func keysAreNotCheckedForAPrefix() throws {
        // Polar's keys start with BA_; nothing on this side should depend on that.
        let t = Temp(), polar = FakePolar { _, _ in (200, FakePolar.activated) }
        for key in ["BA_1234-ABCD", "OTHER-5678", "f3b1c2d4-0000-4000-8000-000000000000"] {
            #expect(try client(polar, t).activate(key: key, label: "Mac").key == key)
        }
        #expect(throws: LicenseClient.Failure.emptyKey) { try client(polar, t).activate(key: "BA_12 34", label: "Mac") }
    }

    @Test func reactivatingTheSameKeyDoesNotUseAnotherSlot() throws {
        let t = Temp(), polar = FakePolar { a, _ in a == "activate" ? (200, FakePolar.activated) : (200, FakePolar.validated) }
        let c = client(polar, t)
        try c.activate(key: "BA_1", label: "Mac")
        try c.activate(key: "BA_1", label: "Mac")
        #expect(polar.calls.map(\.action) == ["activate", "validate"])
    }

    @Test func aDifferentKeyReleasesTheOldActivation() throws {
        let t = Temp(), polar = FakePolar { a, _ in a == "deactivate" ? (204, "") : (200, FakePolar.activated) }
        let c = client(polar, t)
        try c.activate(key: "BA_1", label: "Mac")
        try c.activate(key: "BA_2", label: "Mac")
        #expect(polar.calls.map(\.action) == ["activate", "activate", "deactivate"])
        #expect(polar.calls[2].body["key"] == "BA_1" && polar.calls[2].body["activation_id"] == "act-1")
        #expect(c.store.read()?.key == "BA_2")
    }

    @Test func aMistypedSecondKeyKeepsTheWorkingOne() throws {
        let t = Temp(), polar = FakePolar { a, b in a == "activate" && b["key"] == "BA_TYPO" ? (404, FakePolar.notFound) : (200, FakePolar.activated) }
        let c = client(polar, t)
        try c.activate(key: "BA_1", label: "Mac")
        #expect(throws: LicenseClient.Failure.invalidKey) { try c.activate(key: "BA_TYPO", label: "Mac") }
        #expect(!polar.calls.contains { $0.action == "deactivate" })
        #expect(c.store.read()?.key == "BA_1" && c.status == .active)
    }

    @Test func deactivateFreesTheSlotAndForgetsTheKey() throws {
        let t = Temp(), polar = FakePolar { a, _ in a == "deactivate" ? (204, "") : (200, FakePolar.activated) }
        let c = client(polar, t)
        try c.activate(key: "BA_1", label: "Mac")
        try c.deactivate()
        #expect(polar.calls.last?.body == ["key": "BA_1", "organization_id": realOrg, "activation_id": "act-1"])
        #expect(c.store.read() == nil && c.status == .free)
    }

    @Test func deactivateOfflineKeepsTheKey() throws {
        let t = Temp()
        var offline = false
        let polar = FakePolar { _, _ in if offline { throw URLError(.timedOut) }; return (200, FakePolar.activated) }
        let c = client(polar, t)
        try c.activate(key: "BA_1", label: "Mac")
        offline = true
        #expect(throws: LicenseClient.Failure.self) { try c.deactivate() }
        #expect(c.store.read() != nil)
    }

    @Test func deactivateAnActivationThatsAlreadyGone() throws {
        let t = Temp(), polar = FakePolar { a, _ in a == "deactivate" ? (404, FakePolar.notFound) : (200, FakePolar.activated) }
        let c = client(polar, t)
        try c.activate(key: "BA_1", label: "Mac")
        try c.deactivate()
        #expect(c.store.read() == nil)
    }
}

@Suite struct RevalidationTests {
    /// Activated on day 0; `answer` decides what validate returns from then on.
    func setup(_ answer: @escaping () throws -> (Int, String)) throws -> (LicenseClient, FakePolar, TestClock, Temp) {
        let t = Temp(), clock = TestClock()
        let polar = FakePolar { a, _ in a == "activate" ? (200, FakePolar.activated) : try answer() }
        let c = client(polar, t, clock)
        try c.activate(key: "BA_1", label: "Mac")
        return (c, polar, clock, t)
    }

    @Test func atMostWeekly() throws {
        let (c, polar, clock, _t) = try setup { (200, FakePolar.validated) }
        _ = _t
        clock.advance(days: 6.9)
        #expect(c.revalidateIfDue() == .active)
        #expect(polar.calls.map(\.action) == ["activate"])
        clock.advance(days: 0.2)
        #expect(c.revalidateIfDue() == .active)
        #expect(polar.calls.map(\.action) == ["activate", "validate"])
        #expect(polar.calls[1].body == ["key": "BA_1", "organization_id": realOrg, "activation_id": "act-1"])
        #expect(c.revalidateIfDue() == .active)
        #expect(polar.calls.count == 2)
    }

    @Test func offlineAndPolarErrorsNeverLock() throws {
        var answer: () throws -> (Int, String) = { throw URLError(.notConnectedToInternet) }
        let (c, _, clock, _t) = try setup { try answer() }
        _ = _t
        for _ in 0..<10 { clock.advance(days: 7); #expect(c.revalidateIfDue() == .active) }   // 70 days offline
        answer = { (500, "oops") }
        clock.advance(days: 7); #expect(c.revalidateIfDue() == .active)
        answer = { (429, "") }
        clock.advance(days: 7); #expect(c.revalidateIfDue() == .active)
        answer = { (422, #"{"detail":[]}"#) }
        clock.advance(days: 7); #expect(c.revalidateIfDue() == .active)
        #expect(c.store.read()?.invalidSince == nil)
    }

    @Test func revokedLocksOnlyAfterFourteenDaysOfGrace() throws {
        let (c, _, clock, _t) = try setup { (404, FakePolar.notFound) }
        _ = _t
        clock.advance(days: 7)
        let first = clock.now
        #expect(c.revalidateIfDue() == .grace(until: first.addingTimeInterval(14 * 86_400)))
        #expect(c.status.isUnlocked)
        clock.advance(days: 7)
        #expect(c.revalidateIfDue() == .grace(until: first.addingTimeInterval(14 * 86_400)))   // the clock doesn't restart
        clock.advance(days: 6.9)
        #expect(c.status.isUnlocked)
        clock.advance(days: 0.2)
        #expect(c.status == .lapsed && !c.status.isUnlocked)
        #expect(c.store.read()?.invalidReason == "License key not found.")
    }

    @Test func aValidAnswerEndsTheGracePeriod() throws {
        var answer: () throws -> (Int, String) = { (404, FakePolar.notFound) }
        let (c, _, clock, _t) = try setup { try answer() }
        _ = _t
        clock.advance(days: 7); _ = c.revalidateIfDue()
        clock.advance(days: 14); #expect(c.status == .lapsed)
        answer = { (200, FakePolar.validated) }
        clock.advance(days: 7)
        #expect(c.revalidateIfDue() == .active)
        #expect(c.store.read()?.invalidSince == nil)
    }

    @Test func offlineDuringGraceDoesNotReset() throws {
        var answer: () throws -> (Int, String) = { (404, FakePolar.notFound) }
        let (c, _, clock, _t) = try setup { try answer() }
        _ = _t
        clock.advance(days: 7); _ = c.revalidateIfDue()
        answer = { throw URLError(.timedOut) }
        clock.advance(days: 7); _ = c.revalidateIfDue()
        clock.advance(days: 7.1)
        #expect(c.status == .lapsed)   // offline doesn't extend the grace either
    }

    /// `license deactivate` (or activating another key) from the CLI while the app's weekly check
    /// is waiting on Polar: the check's answer must not write the old license back.
    @Test func aCheckInFlightDoesNotUndoTheCLI() throws {
        for cliAction in ["deactivate", "activate other"] {
            let t = Temp(), clock = TestClock()
            var c: LicenseClient!
            let polar = FakePolar { a, _ in
                if a == "validate" {
                    if cliAction == "deactivate" { c.store.delete() }
                    else { try c.store.write(License(key: "BA_2", activationID: "act-2", label: "Mac", activatedAt: clock.now)) }
                    return (404, FakePolar.notFound)
                }
                return (200, FakePolar.activated)
            }
            c = client(polar, t, clock)
            try c.activate(key: "BA_1", label: "Mac")
            clock.advance(days: 7)
            _ = c.revalidateIfDue()
            if cliAction == "deactivate" {
                #expect(c.store.read() == nil && c.status == .free)
            } else {
                #expect(c.store.read()?.key == "BA_2" && c.store.read()?.invalidSince == nil)
            }
        }
    }

    @Test func gateFromAStoredLicense() {
        let now = at("2026-10-15T12:00:00Z")
        var l = License(key: "k", activationID: "a", label: "Mac", activatedAt: now)
        #expect(ProGate.status(nil, now: now) == .free)
        #expect(ProGate.status(l, now: now) == .active)
        l.invalidSince = now.addingTimeInterval(-13 * 86_400)
        #expect(ProGate.status(l, now: now).isUnlocked)
        l.invalidSince = now.addingTimeInterval(-15 * 86_400)
        #expect(ProGate.status(l, now: now) == .lapsed)
        #expect(!ProGate.needsRevalidation(License(key: "k", activationID: "a", label: "", activatedAt: now), now: now))
        var future = License(key: "k", activationID: "a", label: "", activatedAt: now)
        future.lastCheckedAt = now.addingTimeInterval(30 * 86_400)   // the clock was set back
        #expect(ProGate.needsRevalidation(future, now: now))
    }

    @Test func storeRoundTripsAndIgnoresJunk() throws {
        let t = Temp()
        let store = LicenseStore(directory: t.url)
        #expect(store.read() == nil)
        var l = License(key: "BA_1", activationID: "act", label: "Moiz’s Mac", displayKey: "****-1", activatedAt: at("2026-10-15T12:00:00Z"))
        l.invalidSince = at("2026-10-16T12:00:00Z"); l.invalidReason = "revoked"
        try store.write(l)
        #expect(store.read() == l)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(text.contains("\"activation_id\"") && text.contains("\"invalid_since\""))
        try Data("{".utf8).write(to: store.file)
        #expect(store.read() == nil)
    }
}

/// Hosted naming gets the key from Pro's store, only while Pro is unlocked.
@Suite struct HostedLicenseTests {
    @Test func keyOnlyWhileActiveOrInGrace() throws {
        let t = Temp()
        let store = LicenseStore(directory: t.url)
        #expect(store.licenseKey() == nil, "free")
        var l = License(key: "BA_1234", activationID: "act", label: "Mac", activatedAt: Date().addingTimeInterval(-30 * 86_400))
        try store.write(l)
        #expect(store.licenseKey() == "BA_1234", "active")
        l.invalidSince = Date().addingTimeInterval(-3 * 86_400)
        try store.write(l)
        #expect(store.licenseKey() == "BA_1234", "grace")
        l.invalidSince = Date().addingTimeInterval(-15 * 86_400)
        try store.write(l)
        #expect(store.licenseKey() == nil, "lapsed")
        #expect(LicenseStore().file == Paths.supportDirectory.appendingPathComponent("license"))
    }

    @Test func autoUsesHostedOnlyWithPro() throws {
        let t = Temp()
        let store = LicenseStore(directory: t.url)
        var apple = AppleFMNamer(); apple.status = { .notEnabled }
        #expect(try Backends.resolve("auto", auth: .none, apple: apple, license: store).id == "vision")
        try store.write(License(key: "BA_1234", activationID: "act", label: "Mac", activatedAt: Date()))
        #expect(try Backends.resolve("auto", auth: .none, apple: apple, license: store).id == "hosted")
    }

    /// `license activate` says what hosted naming sends when Automatic now picks it, and only then.
    @Test func activationSaysWhatHostedSends() {
        let l = License(key: "BA_1234ABCD", activationID: "act", label: "Studio Mac", activatedAt: Date())
        let done = "BetterAirdrop Pro is active on “Studio Mac” (key …ABCD)."
        let hosted = EngineStatus.current(config: Config(), hasCredential: false, hasLicense: true)
        #expect(l.activatedMessage(engine: hosted) == done + "\n" + EngineStatus.hostedNotice)
        // It says where photos go (our server, then Anthropic) and how to keep them on the Mac.
        #expect(EngineStatus.hostedNotice.contains("BetterAirdrop's server and on to Anthropic")
                && EngineStatus.hostedNotice.contains("Apple Vision in Settings → Naming"))

        // Your own Claude key, or claude.auto off: hosted isn't the engine, so no notice.
        #expect(l.activatedMessage(engine: EngineStatus.current(config: Config(), hasCredential: true, hasLicense: true)) == done)
        var local = Config(); local.claudeInAuto = false
        #expect(l.activatedMessage(engine: EngineStatus.current(config: local, hasCredential: false, hasLicense: true)) == done)
    }

    /// With "Name PDFs too", a cloud engine's notice says a PDF sends a text extract; on-device engines say nothing.
    @Test func noticeSaysWhatAPDFSends() {
        let l = License(key: "BA_1234ABCD", activationID: "act", label: "Studio Mac", activatedAt: Date())
        let done = "BetterAirdrop Pro is active on “Studio Mac” (key …ABCD)."
        let hosted = EngineStatus.current(config: Config(), hasCredential: false, hasLicense: true)
        let claude = EngineStatus.current(config: Config(), hasCredential: true, hasLicense: true)
        var local = Config(); local.claudeInAuto = false
        let onDevice = EngineStatus.current(config: local, hasCredential: true, appleReady: true, hasLicense: true)
        #expect(l.activatedMessage(engine: hosted, namesPDFs: true) == done + "\n" + EngineStatus.hostedNotice + " " + EngineStatus.pdfNotice)
        #expect(l.activatedMessage(engine: claude, namesPDFs: true) == done + "\n" + EngineStatus.pdfNotice)
        #expect(l.activatedMessage(engine: onDevice, namesPDFs: true) == done)
        #expect(hosted.notice(namesPDFs: false) == EngineStatus.hostedNotice)
        #expect(claude.notice(namesPDFs: false) == nil && onDevice.notice(namesPDFs: true) == nil)
    }
}

/// `betterairdrop status --json` → credentials.hosted: available with Pro, and what the app last heard.
@Suite struct StatusReportHostedTests {
    let now = at("2026-10-15T12:00:00Z")

    func report(pro: Bool, hosted: HostedUsage? = nil) -> StatusReport {
        let state = AppState(version: "0.4.0", pid: 42, updatedAt: now, folder: "~/Downloads", folderAccess: .granted,
                             notifications: .allowed, loginItem: .enabled, watch: .watching, hosted: hosted)
        let license = pro ? License(key: "BA_1", activationID: "act", label: "Mac", activatedAt: now) : nil
        return StatusReport.make(.init(cliVersion: "0.4.0", appPath: "/Applications/BetterAirdrop.app", appVersion: "0.4.0",
                                       appRunning: true, appState: state, setup: SetupRecord(), config: Config(), storedKey: false,
                                       antLoggedIn: false, lockHolder: nil, license: license, now: now))
    }

    @Test func freeProAndLastHeard() throws {
        #expect(report(pro: false).credentials.hosted == .init(available: false))
        #expect(report(pro: true).credentials.hosted == .init(available: true))
        #expect(report(pro: true).engine.active == "Hosted (Pro)")
        let resets = at("2026-11-01T00:00:00Z")
        let heard = HostedUsage(remaining: 47, resetsAt: resets, lastError: "network error: offline", updatedAt: now)
        #expect(report(pro: true, hosted: heard).credentials.hosted
                == .init(available: true, remaining: 47, resetsAt: resets, lastError: "network error: offline"))
        #expect(report(pro: true, hosted: heard).engine.detail == "47 names left this month")
        // After the month resets the old count is dropped.
        let old = HostedUsage(remaining: 0, resetsAt: at("2026-10-01T00:00:00Z"), lastError: "monthly hosted limit reached", updatedAt: now)
        #expect(report(pro: true, hosted: old).credentials.hosted == .init(available: true))
    }

    @Test func jsonShape() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(report(pro: false).json().utf8)) as! [String: Any]
        let hosted = (obj["credentials"] as! [String: Any])["hosted"] as! [String: Any]
        #expect(Set(hosted.keys) == ["available", "remaining", "resets_at", "last_error"], "always all four keys")
        #expect(hosted["available"] as? Bool == false && hosted["remaining"] is NSNull)
        let heard = HostedUsage(remaining: 3, resetsAt: at("2026-11-01T00:00:00Z"), updatedAt: now)
        let pro = try JSONSerialization.jsonObject(with: Data(report(pro: true, hosted: heard).json().utf8)) as! [String: Any]
        let h = (pro["credentials"] as! [String: Any])["hosted"] as! [String: Any]
        #expect(h["remaining"] as? Int == 3 && h["resets_at"] as? String == "2026-11-01T00:00:00Z")
    }

    @Test func appStateRoundTripsAndOldFilesStillRead() throws {
        let t = Temp()
        let url = t.url.appendingPathComponent("app-state.json")
        let heard = HostedUsage(remaining: 3, resetsAt: at("2026-11-01T00:00:00Z"), lastError: nil, updatedAt: now)
        let s = AppState(version: "0.4.0", pid: 42, updatedAt: now, folder: "~/Downloads", folderAccess: .granted,
                         notifications: .allowed, loginItem: .enabled, watch: .watching, hosted: heard)
        try s.save(to: url)
        #expect(AppState.load(from: url)?.hosted == heard)
        try Data(#"{"schema":1,"version":"0.3.9","pid":1,"updated_at":"2026-10-15T12:00:00Z","folder":"~/Downloads","folder_access":"granted","notifications":"allowed","login_item":"enabled","watch":"watching"}"#.utf8).write(to: url)
        #expect(AppState.load(from: url)?.hosted == nil && AppState.load(from: url)?.version == "0.3.9")
    }
}

/// `betterairdrop status --json` → credentials.license, beside credentials.claude.
@Suite struct StatusReportLicenseTests {
    let now = at("2026-10-15T12:00:00Z")

    func report(_ license: License?) -> StatusReport {
        let state = AppState(version: "0.4.0", pid: 42, updatedAt: now, folder: "~/Downloads", folderAccess: .granted,
                             notifications: .allowed, loginItem: .enabled, watch: .watching)
        return StatusReport.make(.init(cliVersion: "0.4.0", appPath: "/Applications/BetterAirdrop.app", appVersion: "0.4.0",
                                       appRunning: true, appState: state, setup: SetupRecord(), config: Config(), storedKey: true,
                                       antLoggedIn: false, lockHolder: nil, license: license, now: now))
    }

    func license(invalidDaysAgo: Double? = nil) -> License {
        var l = License(key: "BA_1", activationID: "act", label: "Mac", displayKey: "****-ABCD", activatedAt: now.addingTimeInterval(-30 * 86_400))
        l.invalidSince = invalidDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        return l
    }

    @Test func states() {
        #expect(report(nil).credentials.license == .init(state: "none", pro: false))
        #expect(report(license()).credentials.license == .init(state: "active", pro: true, key: "****-ABCD"))
        #expect(report(license(invalidDaysAgo: 3)).credentials.license
                == .init(state: "grace", pro: true, key: "****-ABCD", graceUntil: now.addingTimeInterval(11 * 86_400)))
        #expect(report(license(invalidDaysAgo: 15)).credentials.license == .init(state: "invalid", pro: false, key: "****-ABCD"))
    }

    @Test func nextStepOnlyForARejectedKey() {
        #expect(report(nil).nextSteps.isEmpty)               // no Pro nag for free users
        #expect(report(license()).nextSteps.isEmpty)
        for l in [license(invalidDaysAgo: 3), license(invalidDaysAgo: 15)] {
            let steps = report(l).nextSteps
            #expect(steps.count == 1)
            #expect(steps[0].who == "human" && !steps[0].required)
            #expect(steps[0].command == "betterairdrop license activate <key>")
        }
        #expect(report(license()).ready)                      // Pro never affects `ready`
    }

    @Test func jsonShape() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(report(license(invalidDaysAgo: 3)).json().utf8)) as! [String: Any]
        let lic = (obj["credentials"] as! [String: Any])["license"] as! [String: Any]
        #expect(Set(lic.keys) == ["state", "pro", "key", "grace_until"])
        #expect(lic["state"] as? String == "grace" && lic["pro"] as? Bool == true)
        let none = try JSONSerialization.jsonObject(with: Data(report(nil).json().utf8)) as! [String: Any]
        #expect(((none["credentials"] as! [String: Any])["license"] as! [String: Any]).keys.sorted() == ["pro", "state"])
    }
}

@Suite struct ReceiptsCSVTests {
    func journal(_ t: Temp) throws -> Journal {
        let j = Journal(url: t.url.appendingPathComponent("journal.jsonl"))
        func add(_ batch: String, _ source: String, _ target: String, summary: String, receipt: JournalRecord.ReceiptFields?, undo: Bool = false) throws {
            var r = JournalRecord(op: .begin, batch: batch, action: .rename, source: source, target: target,
                                  sourceSHA1: "a", outputSHA1: "a", summary: summary)
            r.receipt = receipt
            try j.append(r)
            try j.append(r.with(.done))
            if undo { try j.append(r.with(.undo)) }
        }
        try add("b1", "/d/IMG_2.png", "/d/Receipts/2026-10/2026-10-02_receipt_cafe.png", summary: "receipt: coffee",
                receipt: .init(date: "2026-10-02", merchant: "Café \"Olé\", Inc", total: "4.50"))
        try add("b1", "/d/IMG_1.png", "/d/2026-09-30_receipt_loblaws_84-12.png", summary: "receipt: groceries",
                receipt: .init(date: "2026-09-30", merchant: "Loblaws", total: "84.12"))
        try add("b2", "/d/IMG_3.png", "/d/lamp.png", summary: "photo: lamp", receipt: nil)
        try add("b3", "/d/IMG_4.png", "/d/undone.png", summary: "receipt: x", receipt: .init(date: "2026-01-01", merchant: "X", total: "1"), undo: true)
        try add("b4", "/d/IMG_5.png", "/d/old.png", summary: "receipt: from an older build", receipt: nil)
        try add("b5", "/d/IMG_6.png", "/d/evil.png", summary: "receipt: x", receipt: .init(date: "2026-10-03", merchant: "=HYPERLINK(\"x\")", total: "-5.00"))
        return j
    }

    @Test func exportsDoneReceiptsOldestFirst() throws {
        let t = Temp()
        let rows = ReceiptsCSV.rows(try journal(t).entries())
        let today = String(Journal.timestamp().prefix(10))
        // Not the photo, not the undone receipt; the older-build receipt is dated the day it was renamed.
        #expect(Set(rows.map(\.file)) == ["/d/2026-09-30_receipt_loblaws_84-12.png", "/d/Receipts/2026-10/2026-10-02_receipt_cafe.png",
                                          "/d/evil.png", "/d/old.png"])
        #expect(rows.map(\.date) == rows.map(\.date).sorted())
        #expect(rows.first { $0.file == "/d/old.png" } == .init(date: today, merchant: "", total: "", file: "/d/old.png"))
    }

    @Test func quotingAndFormulaGuard() throws {
        let t = Temp()
        let csv = ReceiptsCSV.make(try journal(t).entries())
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0] == "date,merchant,total,file")
        #expect(lines[1] == "2026-09-30,Loblaws,84.12,/d/2026-09-30_receipt_loblaws_84-12.png")
        #expect(lines[2] == "2026-10-02,\"Café \"\"Olé\"\", Inc\",4.50,/d/Receipts/2026-10/2026-10-02_receipt_cafe.png")
        #expect(lines.contains("2026-10-03,\"'=HYPERLINK(\"\"x\"\")\",-5.00,/d/evil.png"))
        #expect(csv.hasSuffix("\r\n"))
        // A refund stays a number; anything else starting with - is text.
        #expect(ReceiptsCSV.cell("-5.00") == "-5.00" && ReceiptsCSV.cell("-1,234.50") == "\"-1,234.50\"")
        #expect(ReceiptsCSV.cell("-1+1") == "'-1+1" && ReceiptsCSV.cell("-2+3+cmd|' /C calc'!A0") == "'-2+3+cmd|' /C calc'!A0")
        #expect(ReceiptsCSV.cell("+15") == "'+15" && ReceiptsCSV.cell("@SUM(A1)") == "'@SUM(A1)")
        #expect(ReceiptsCSV.make([]) == "date,merchant,total,file\r\n")
    }
}

@Suite struct ProMentionTests {
    @Test func onceAfterTwentyRenames() {
        #expect(!ProMention.shouldShow(renames: 19, isPro: false, alreadyShown: false))
        #expect(ProMention.shouldShow(renames: 20, isPro: false, alreadyShown: false))
        #expect(!ProMention.shouldShow(renames: 200, isPro: false, alreadyShown: true))
        #expect(!ProMention.shouldShow(renames: 200, isPro: true, alreadyShown: false))
    }
}

@Suite struct WatchPlanTests {
    let downloads = URL(fileURLWithPath: "/Users/t/Downloads")
    let desktop = URL(fileURLWithPath: "/Users/t/Desktop")
    let inbox = URL(fileURLWithPath: "/Users/t/Pictures/Inbox")

    func summary(_ p: WatchPlan) -> [String] { p.entries.map { "\($0.folder.path) \($0.role) \($0.intake) \($0.movies)" } }

    @Test func freeIsJustTheAirDropFolder() {
        #expect(summary(.make(main: downloads, mainAirdropOnly: true, screenshots: nil, extras: []))
                == ["/Users/t/Downloads airdrop airdrop true"])
        #expect(summary(.make(main: downloads, mainAirdropOnly: false, screenshots: nil, extras: []))
                == ["/Users/t/Downloads airdrop all true"])
    }

    @Test func proAddsScreenshotsAndFolders() {
        #expect(summary(.make(main: downloads, mainAirdropOnly: true, screenshots: desktop, extras: [inbox])) == [
            "/Users/t/Downloads airdrop airdrop true",
            "/Users/t/Desktop screenshots screenshots false",
            "/Users/t/Pictures/Inbox folder all false",
        ])
    }

    @Test func neverWatchesAFolderTwice() {
        // Screenshots saved to Downloads: the AirDrop watcher takes them too.
        #expect(summary(.make(main: downloads, mainAirdropOnly: true, screenshots: URL(fileURLWithPath: "/Users/t/downloads/"), extras: []))
                == ["/Users/t/Downloads airdrop airdropAndScreenshots true"])
        #expect(summary(.make(main: downloads, mainAirdropOnly: false, screenshots: downloads, extras: []))
                == ["/Users/t/Downloads airdrop all true"])
        // Downloads added as a folder, a folder added twice, the screenshot folder added as a folder.
        #expect(summary(.make(main: downloads, mainAirdropOnly: true, screenshots: desktop, extras: [downloads, inbox, inbox, desktop])) == [
            "/Users/t/Downloads airdrop airdrop true",
            "/Users/t/Pictures/Inbox folder all false",
            "/Users/t/Desktop folder all false",
        ])
    }
}

@Suite struct NameBuilderTests {
    @Test func buildsTemplates() {
        var b = NameBuilder.standard
        #expect(b.template == "{date}_{place}_{subject}")
        b.separator = .hyphen
        #expect(b.template == "{date}-{place}-{subject}")
        b.toggle(.kind)
        #expect(b.template == "{date}-{place}-{subject}-{kind}")
        b.move(.kind, by: -1)
        #expect(b.template == "{date}-{place}-{kind}-{subject}")
        b.move(.kind, by: -9)   // stops at the start
        #expect(b.template == "{kind}-{date}-{place}-{subject}")
        b.move(.date, by: 9)
        #expect(b.template == "{kind}-{place}-{subject}-{date}")
        b.move(.date, by: -2)
        b.toggle(.city)
        b.toggle(.description)   // stays on
        #expect(b.template == "{kind}-{date}-{subject}")
        #expect(b.rows.map(\.part) == [.kind, .date, .description, .city])
        #expect(b.rows.map(\.on) == [true, true, true, false])
    }

    @Test func readsItsOwnTemplatesOnly() {
        #expect(NameBuilder(template: "{date}_{place}_{subject}") == .standard)
        #expect(NameBuilder(template: "{subject} {date}")?.separator == .space)
        #expect(NameBuilder(template: "{kind}-{subject}")?.parts == [.kind, .description])
        #expect(NameBuilder(template: "{date}_{device}_{subject}") == nil)   // not a builder part
        #expect(NameBuilder(template: "{date}_{place}") == nil)              // no description
        #expect(NameBuilder(template: "IMG {subject}") == nil)
        #expect(NameBuilder(template: "{date}_{subject}-{place}") == nil)    // mixed separators
    }

    @Test func everyBuilderTemplateIsValidAndPreviews() throws {
        for sep in NameBuilder.Separator.allCases {
            var b = NameBuilder(parts: [.description], separator: sep)
            for p in [NameBuilder.Part.date, .city, .kind] {
                b.toggle(p)
                _ = try Template(b.template)
                #expect(NameBuilder(template: b.template) == b)
            }
        }
        #expect(try TemplatePreview.render("{date}-{place}-{subject}", dateFormat: .compact).get() == "20260924-toronto-walnut-lamp-on-oak-sideboard.jpg")
        #expect(try TemplatePreview.render("{subject} {date}", dateFormat: .dayFirst).get() == "walnut-lamp-on-oak-sideboard 24-09-2026.jpg")
        #expect(try TemplatePreview.render("{kind}_{subject}").get() == "photo_walnut-lamp-on-oak-sideboard.jpg")
    }
}

@Suite struct PhotoFoldersTests {
    @Test func findsImagesButNeverInsidePackages() throws {
        let t = Temp()
        let fm = FileManager.default
        func touch(_ p: String) {
            let u = t.url.appendingPathComponent(p)
            try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data("x".utf8))
        }
        touch("a/IMG_1.HEIC"); touch("a/sub/IMG_2.jpg"); touch("a/notes.txt"); touch("a/.hidden.png")
        touch("a/Photos Library.photoslibrary/originals/IMG_3.HEIC")
        touch("a/Some.app/Contents/icon.png")
        let a = t.url.appendingPathComponent("a")
        let base = a.resolvingSymlinksInPath().path + "/"
        #expect(PhotoFolders.images(in: a).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") } == ["IMG_1.HEIC", "sub/IMG_2.jpg"])
        #expect(PhotoFolders.images(in: a.appendingPathComponent("Photos Library.photoslibrary")).isEmpty)
        #expect(PhotoFolders.images(in: a, limit: 1).count == 1)
        let (files, folders, _) = PhotoFolders.split([a.appendingPathComponent("IMG_1.HEIC"), a.appendingPathComponent("notes.txt"), a.appendingPathComponent("sub"),
                                                   a.appendingPathComponent("Photos Library.photoslibrary")])
        #expect(files.map(\.lastPathComponent) == ["IMG_1.HEIC"])
        #expect(folders.map(\.lastPathComponent) == ["sub"])
    }
}

/// The free Pro naming trial: what the app shows, when it offers it, and `status --json`'s `credentials.trial`.
@Suite struct ProTrialTests {
    let now = at("2026-10-15T12:00:00Z")
    var on: Config { var c = Config(); c.proTrial = true; return c }

    @Test func engineStatus() {
        let fresh = EngineStatus.trialRemaining(config: on, trial: nil, isPro: false)
        #expect(fresh == 25)
        #expect(EngineStatus.current(config: on, hasCredential: false, trialRemaining: fresh)
                == EngineStatus(name: "Hosted (Pro)", detail: "free trial, 25 names left"))
        #expect(EngineStatus.current(config: on, hasCredential: false, trialRemaining: 1).detail == "free trial, 1 name left")
        #expect(EngineStatus.current(config: on, hasCredential: true, trialRemaining: 25).isClaude, "your own key comes first")
        #expect(EngineStatus.current(config: on, hasCredential: false, appleReady: true, hostedProblem: "busy", trialRemaining: 3)
                == EngineStatus(name: "Apple Intelligence", detail: "busy"))
        var local = on; local.claudeInAuto = false
        #expect(EngineStatus.current(config: local, hasCredential: false, trialRemaining: 25).name == "Apple Vision")

        // Off, used up, or Pro: no trial, so the free engines exactly as before.
        let id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        #expect(EngineStatus.trialRemaining(config: Config(), trial: nil, isPro: false) == nil)
        #expect(EngineStatus.trialRemaining(config: on, trial: TrialState(id: id, remaining: 0, usedUp: true), isPro: false) == nil)
        #expect(EngineStatus.trialRemaining(config: on, trial: nil, isPro: true) == nil)
        #expect(EngineStatus.trialRemaining(config: on, trial: TrialState(id: id, remaining: 7), isPro: false) == 7)
        #expect(EngineStatus.current(config: on, hasCredential: false, trialRemaining: nil).name == "Apple Vision")
    }

    @Test func offerOnlyToNewFreeUsersOnAutomatic() {
        let id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        func offer(_ c: Config = Config(), pro: Bool = false, key: Bool = false, trial: TrialState? = nil, dismissed: Bool = false) -> Bool {
            ProTrial.shouldOffer(config: c, isPro: pro, hasCredential: key, trial: trial, dismissed: dismissed)
        }
        #expect(offer())
        #expect(!offer(pro: true) && !offer(key: true) && !offer(dismissed: true))
        #expect(!offer(on), "already on")
        #expect(!offer(trial: TrialState(id: id, remaining: 0, usedUp: true)), "already tried, then turned off")
        var vision = Config(); vision.backend = "vision"
        var local = Config(); local.claudeInAuto = false
        #expect(!offer(vision) && !offer(local), "someone who chose to stay on this Mac isn't asked")
    }

    @Test func copy() {
        #expect(ProTrial.ended + " " + ProTrial.keep == "Your 25 free Pro names are used up. Keep names like these: $19")
        #expect(ProTrial.notice.contains("BetterAirdrop's server") && ProTrial.notice.contains("Anthropic"))
        #expect(ProTrial.settingsLine(config: Config(), trial: nil) == ProTrial.offer + " " + ProTrial.notice)
        let id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        #expect(ProTrial.settingsLine(config: on, trial: TrialState(id: id, remaining: 12)).hasPrefix("12 of 25 free names left."))
        #expect(ProTrial.settingsLine(config: on, trial: TrialState(id: id, remaining: 0, usedUp: true)) == ProTrial.ended)
    }

    func report(_ config: Config, trial: TrialState?) -> StatusReport {
        StatusReport.make(.init(cliVersion: "0.4.1", appPath: nil, appVersion: nil, appRunning: false, appState: nil, setup: nil,
                                config: config, storedKey: false, antLoggedIn: false, lockHolder: nil, trial: trial, now: now))
    }

    @Test func statusJSON() throws {
        let id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        let r = report(on, trial: TrialState(id: id, remaining: 20))
        #expect(r.engine.active == "Hosted (Pro)" && r.engine.detail == "free trial, 20 names left")
        #expect(r.credentials.trial == .init(enabled: true, state: TrialState(id: id, remaining: 20)))
        let obj = try JSONSerialization.jsonObject(with: Data(report(Config(), trial: nil).json().utf8)) as! [String: Any]
        let trial = (obj["credentials"] as! [String: Any])["trial"] as! [String: Any]
        #expect(Set(trial.keys) == ["enabled", "remaining", "used_up"], "always all three keys")
        #expect(trial["enabled"] as? Bool == false && trial["remaining"] is NSNull && trial["used_up"] as? Bool == false)
        #expect(!(try report(on, trial: TrialState(id: id)).json()).contains(id), "the trial ID isn't reported")
        let done = report(on, trial: TrialState(id: id, remaining: 0, usedUp: true))
        #expect(done.engine.active == "Apple Vision" && done.credentials.trial?.usedUp == true)
    }
}
