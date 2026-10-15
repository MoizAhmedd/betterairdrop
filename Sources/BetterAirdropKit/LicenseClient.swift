import BetterAirdropCore
import Foundation

/// Activates, re-checks and deactivates a Pro key with Polar's customer-portal API
/// (`POST /v1/customer-portal/license-keys/{activate,validate,deactivate}`). These endpoints are
/// meant for desktop apps: they take the organization ID and need no access token, so there's no
/// secret in the app and no server of ours.
///
/// Responses, from Polar's API reference (2026-10):
/// - activate `{key, organization_id, label}` → 200 with the activation (`id`, `license_key`),
///   403 NotPermitted (revoked, disabled, expired or at its activation limit), 404 unknown key.
/// - validate `{key, organization_id, activation_id}` → 200 with the key (`status: "granted"`),
///   404 if it's unknown, revoked, disabled or expired, or the activation doesn't match.
/// - deactivate `{key, organization_id, activation_id}` → 204, or 404 if the activation is gone.
///
/// Synchronous: call it off the main thread.
public struct LicenseClient: Sendable {
    public var api: URL
    public var organizationID: String
    public var transport: any HTTPTransport
    public var store: LicenseStore
    public var now: @Sendable () -> Date

    public init(api: URL = Polar.endpoint().api, organizationID: String = Polar.endpoint().organizationID,
                transport: any HTTPTransport = URLSessionTransport(), store: LicenseStore = LicenseStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api; self.organizationID = organizationID; self.transport = transport; self.store = store; self.now = now
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The organization ID is still the placeholder: Pro isn't on sale yet.
        case notAvailable
        case emptyKey
        case invalidKey
        case activationLimit(String)
        case notPermitted(String)
        case unreachable(String)
        case couldNotSave(String)

        public var description: String {
            switch self {
            case .notAvailable: "BetterAirdrop Pro isn't on sale yet, so there's nothing to activate. Everything else in BetterAirdrop works without it."
            case .emptyKey: "Paste the license key from your Polar receipt."
            case .invalidKey: "Polar doesn't know this key. Check that you copied all of it from your receipt email."
            case .activationLimit(let d): "This key is already active on 3 Macs. Deactivate it on one of them (Settings → Pro), or free a Mac from the link in your Polar receipt. (\(d))"
            case .notPermitted(let d): "Polar won't activate this key: \(d)"
            case .unreachable(let d): d
            case .couldNotSave(let d): "Activated, but the license couldn't be saved on this Mac: \(d)"
            }
        }
    }

    /// The Mac's name, used as the activation's label in Polar ("Moiz's MacBook Air").
    public static func macName() -> String {
        Host.current().localizedName.flatMap { $0.isEmpty ? nil : $0 } ?? ProcessInfo.processInfo.hostName
    }

    var canActivate: Bool { Polar.isReal(organizationID: organizationID) }

    // MARK: - Activate

    /// Activates `key` on this Mac and saves it. Activating the key this Mac already holds just
    /// re-checks it (no second activation); a different key replaces the old one once Polar has
    /// accepted it, and only then is the old one's activation released (so a mistyped key never
    /// costs the Mac a working license).
    @discardableResult
    public func activate(key raw: String, label: String = LicenseClient.macName()) throws -> License {
        guard canActivate else { throw Failure.notAvailable }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw Failure.emptyKey }

        let previous = store.read()
        if let current = previous, current.key == key {
            switch check(current) {
            case .valid(let display):
                var l = current
                l.displayKey = display ?? l.displayKey
                l.lastCheckedAt = now(); l.lastValidatedAt = now(); l.invalidSince = nil; l.invalidReason = nil
                try save(l)
                return l
            case .unknown:
                return current   // no verdict: keep what's there rather than use up another slot
            case .invalid:
                break            // this activation is gone (or the key was revoked): activate again below
            }
        }

        let (status, data): (Int, Data)
        do {
            (status, data) = try post("activate", ["key": key, "organization_id": organizationID, "label": label])
        } catch {
            throw Failure.unreachable("Couldn't reach Polar to activate the key. Check your internet connection and try again.")
        }
        switch status {
        case 200..<300:
            guard let obj = Self.json(data), let id = obj["id"] as? String, !id.isEmpty else {
                throw Failure.unreachable("Polar's answer didn't include an activation. Try again in a minute.")
            }
            let display = (obj["license_key"] as? [String: Any])?["display_key"] as? String
            let l = License(key: key, activationID: id, label: label, displayKey: display, activatedAt: now())
            try save(l)
            if let old = previous, old.key != key { _ = try? release(old) }   // best effort: frees the old key's slot
            return l
        case 403:
            let d = Self.detail(data) ?? "not permitted"
            throw d.lowercased().contains("limit") ? Failure.activationLimit(d) : Failure.notPermitted(d)
        case 404:
            throw Failure.invalidKey
        case 422:
            throw Failure.invalidKey
        default:
            throw Failure.unreachable("Polar answered with an error (\(status)). Try again in a few minutes.")
        }
    }

    private func save(_ l: License) throws {
        do { try store.write(l) } catch { throw Failure.couldNotSave(error.localizedDescription) }
    }

    // MARK: - Validate

    public enum Check: Equatable, Sendable {
        /// Polar says the key and this activation are good (`display_key` if it sent one).
        case valid(String?)
        /// Polar explicitly says the key is unknown, revoked, disabled, expired, or this activation is gone.
        case invalid(String)
        /// No answer, or an answer that isn't a verdict (5xx, 429, 422…). Never locks Pro.
        case unknown(String)
    }

    /// One validate call. Doesn't touch the store.
    public func check(_ l: License) -> Check {
        guard canActivate else { return .unknown("Pro isn't on sale yet") }
        let (status, data): (Int, Data)
        do {
            (status, data) = try post("validate", ["key": l.key, "organization_id": organizationID, "activation_id": l.activationID])
        } catch {
            return .unknown("couldn't reach Polar")
        }
        switch status {
        case 200..<300:
            let obj = Self.json(data)
            if let s = obj?["status"] as? String, s != "granted" { return .invalid("the key is \(s)") }
            return .valid(obj?["display_key"] as? String)
        case 403, 404:
            return .invalid(Self.detail(data) ?? "Polar says this key is no longer valid")
        default:
            return .unknown("Polar answered \(status)")
        }
    }

    /// The weekly re-check: asks Polar if it's been a week, records the answer and returns the
    /// status. Offline or a Polar error leaves everything as it was (Pro stays on).
    @discardableResult
    public func revalidateIfDue() -> ProStatus {
        guard let asked = store.read() else { return .free }
        guard ProGate.needsRevalidation(asked, now: now()), canActivate else { return ProGate.status(asked, now: now()) }
        let result = check(asked)
        // `license activate|deactivate` may have replaced or removed the license while Polar was
        // asked (up to 15 s). Record the answer only on the activation it's about, so a deactivated
        // key isn't written back and a newly activated one isn't overwritten.
        guard var l = store.read(), l.key == asked.key, l.activationID == asked.activationID else { return status }
        l.lastCheckedAt = now()
        switch result {
        case .valid(let display):
            l.lastValidatedAt = now()
            l.invalidSince = nil
            l.invalidReason = nil
            if let display { l.displayKey = display }
        case .invalid(let why):
            if l.invalidSince == nil { l.invalidSince = now() }
            l.invalidReason = why
        case .unknown:
            break
        }
        try? store.write(l)
        return ProGate.status(l, now: now())
    }

    public var status: ProStatus { ProGate.status(store.read(), now: now()) }

    // MARK: - Deactivate

    /// Frees this Mac's activation at Polar and forgets the key. If Polar can't be reached the key
    /// is kept (so the slot isn't silently lost) and this throws.
    public func deactivate() throws {
        guard let l = store.read() else { return }
        guard canActivate else { store.delete(); return }
        let status: Int
        do {
            status = try release(l)
        } catch {
            throw Failure.unreachable("Couldn't reach Polar, so this Mac is still activated. Try again when you're online.")
        }
        switch status {
        case 200..<300, 404:   // 404: the activation was already removed (e.g. from Polar's portal)
            store.delete()
        default:
            throw Failure.unreachable("Polar answered with an error (\(status)), so this Mac is still activated. Try again in a few minutes.")
        }
    }

    /// Asks Polar to drop `l`'s activation; returns the HTTP status. Doesn't touch the store.
    private func release(_ l: License) throws -> Int {
        try post("deactivate", ["key": l.key, "organization_id": organizationID, "activation_id": l.activationID]).0
    }

    // MARK: - HTTP

    private func post(_ action: String, _ body: [String: String]) throws -> (Int, Data) {
        var req = URLRequest(url: api.appendingPathComponent("v1/customer-portal/license-keys/\(action)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (resp, data) = try transport.send(req)
        return (resp.statusCode, data)
    }

    static func json(_ d: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: d) as? [String: Any] }

    /// Polar's error `detail` (a string for NotPermitted/ResourceNotFound).
    static func detail(_ d: Data) -> String? { json(d)?["detail"] as? String }
}
