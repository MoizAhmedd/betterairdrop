import ArgumentParser
import BetterAirdropCore
import BetterAirdropKit
import Foundation

struct LicenseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "license",
        abstract: "Activate BetterAirdrop Pro on this Mac (the menu-bar app's extra features).",
        discussion: "Pro is a one-time purchase for 3 Macs, sold through Polar. The key is checked with Polar when "
            + "it's activated and then about once a week; Pro stays on when Polar can't be reached. The key and this "
            + "Mac's activation are kept in ~/Library/Application Support/betterairdrop/license (readable only by you). "
            + "Everything in this command-line tool works without Pro.",
        subcommands: [Activate.self, Status.self, Deactivate.self]
    )

    struct Activate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Activate a Pro license key on this Mac (uses one of its 3 Macs).")

        @Argument(help: "The license key from your Polar receipt.")
        var key: String

        @OptionGroup var global: GlobalOptions

        func run() throws {
            do {
                let l = try LicenseClient().activate(key: key)
                AppSignal.reload.post()   // a running app turns Pro on now
                let engine = EngineStatus.current(config: (try? global.loadConfig()) ?? Config(),
                                                  hasCredential: ClaudeAuth.shared.resolve() != nil,
                                                  appleReady: AppleIntelligenceStatus.current.isAvailable, hasLicense: true)
                print(l.activatedMessage(engine: engine))
            } catch let f as LicenseClient.Failure {
                stderr(f.description)
                throw ExitCode(1)
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether Pro is active on this Mac (never prints the full key).")

        @Flag(help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            let store = LicenseStore()
            let license = store.read()
            let report = Report(license: license, status: ProGate.status(license))
            if json { try printJSON(report); return }
            print(report.text)
        }
    }

    struct Deactivate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Free this Mac's activation at Polar and remove the key from this Mac.")

        func run() throws {
            let store = LicenseStore()
            guard store.read() != nil else { print("Pro isn't activated on this Mac."); return }
            do {
                try LicenseClient(store: store).deactivate()
                AppSignal.reload.post()
                print("Deactivated. This Mac's slot is free again; the key works on another Mac.")
            } catch let f as LicenseClient.Failure {
                stderr(f.description)
                throw ExitCode(1)
            }
        }
    }

    /// `license status --json`. Stable keys, for scripts and agents.
    struct Report: Encodable {
        var pro: Bool
        /// none | active | grace | invalid (the same values as `status --json` → credentials.license.state)
        var state: String
        var graceUntil: Date?
        var key: String?
        var label: String?
        var activationID: String?
        var activatedAt: Date?
        var lastValidatedAt: Date?
        var lastCheckedAt: Date?
        var onSale: Bool
        var buyURL: String?

        enum CodingKeys: String, CodingKey {
            case pro, state, key, label
            case graceUntil = "grace_until", activationID = "activation_id", activatedAt = "activated_at"
            case lastValidatedAt = "last_validated_at", lastCheckedAt = "last_checked_at", onSale = "on_sale", buyURL = "buy_url"
        }

        init(license: License?, status: ProStatus) {
            pro = status.isUnlocked
            switch status {
            case .free: state = "none"
            case .active: state = "active"
            case .grace(let until): state = "grace"; graceUntil = until
            case .lapsed: state = "invalid"
            }
            key = license?.maskedKey
            label = license?.label
            activationID = license?.activationID
            activatedAt = license?.activatedAt
            lastValidatedAt = license?.lastValidatedAt
            lastCheckedAt = license?.lastCheckedAt
            onSale = Polar.canBuy
            buyURL = Polar.canBuy ? Polar.checkoutURL : nil
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            let iso = ISO8601DateFormatter()
            try c.encode(pro, forKey: .pro)
            try c.encode(state, forKey: .state)
            try c.encode(graceUntil.map(iso.string), forKey: .graceUntil)
            try c.encode(key, forKey: .key)
            try c.encode(label, forKey: .label)
            try c.encode(activationID, forKey: .activationID)
            try c.encode(activatedAt.map(iso.string), forKey: .activatedAt)
            try c.encode(lastValidatedAt.map(iso.string), forKey: .lastValidatedAt)
            try c.encode(lastCheckedAt.map(iso.string), forKey: .lastCheckedAt)
            try c.encode(onSale, forKey: .onSale)
            try c.encode(buyURL, forKey: .buyURL)
        }

        var text: String {
            switch state {
            case "none":
                return "Pro isn't activated on this Mac. " + (onSale ? "Buy it at \(buyURL!), then run `betterairdrop license activate <key>`." : "It isn't on sale yet.")
            case "grace":
                let f = DateFormatter(); f.dateStyle = .medium
                return "Pro is on (key \(key ?? "?"), “\(label ?? "")”), but Polar says the key is no longer valid. It stays on until \(f.string(from: graceUntil!))."
            case "invalid":
                return "Pro is off: Polar says key \(key ?? "?") is no longer valid. Activate a valid key with `betterairdrop license activate <key>`."
            default:
                let checked = lastValidatedAt.map { " Last checked with Polar \(RelativeTime.string($0))." } ?? ""
                return "Pro is active on “\(label ?? "this Mac")” (key \(key ?? "?")).\(checked)"
            }
        }
    }
}
