import BetterAirdropCore
import Foundation

/// What the app shows about the naming engine ("Claude (your API key)", "Apple Vision (basic)"…).
public enum EngineChoice: String, CaseIterable, Sendable {
    case auto, apple, claude, vision

    public var title: String {
        switch self {
        case .auto: "Automatic (recommended)"
        case .apple: "Apple Intelligence"
        case .claude: "Claude (your API key)"
        case .vision: "Apple Vision (basic)"
        }
    }
}

public struct EngineStatus: Equatable, Sendable {
    /// The engine that will name the next photo. `status --json`'s `engine.active`, so it stays as
    /// it was ("Hosted (Pro)"); people see `title`.
    public var name: String
    /// e.g. "Vision if offline". `status --json`'s `engine.detail`; people see `subtitle`.
    public var detail: String?
    /// Claude with the user's own credential names the next photo.
    public var isClaude = false
    /// What people see instead of `detail`, when the two differ.
    var shownDetail: String?

    /// The engine's name as people see it: hosted naming is "Pro naming".
    public var title: String { Self.title(name) }
    /// The line next to `title`, e.g. "Apple Vision if offline".
    public var subtitle: String? { shownDetail ?? detail }

    /// `hasCredential`: a Claude credential resolves (key, env or `ant`). `appleReady`: Foundation Models is usable.
    /// `hasLicense`: Pro is active or in grace on this Mac (hosted naming). `hostedProblem`: why
    /// hosted naming is being skipped right now (`HostedNamer.currentProblem`), e.g. its monthly
    /// limit. `hostedRemaining`: names left this month, as the server last said. `trialRemaining`:
    /// the free trial is on and has this many names left (`trialRemaining(...)`); nil = no trial.
    /// `auto` follows `Backends.resolve`: Claude, hosted, the trial, Apple Intelligence, Vision.
    /// `claudeProblem`: Claude's credential was rejected (`ClaudeAuth.Problem.message`), so photos
    /// are named the way they would be without it, with the problem as the detail.
    public static func current(config: Config, hasCredential: Bool, appleReady: Bool = false,
                               hasLicense: Bool = false, hostedProblem: String? = nil, hostedRemaining: Int? = nil,
                               trialRemaining: Int? = nil, claudeProblem: String? = nil) -> EngineStatus {
        let claude = EngineStatus(name: modelName(config.claudeModel), detail: "Vision if offline", isClaude: true,
                                  shownDetail: "Apple Vision if offline")
        // Hosted falls back to Apple Intelligence when it's ready, else Vision (Backends.onDevice).
        let onDevice = appleReady ? "Apple Intelligence" : "Apple Vision"
        let left = hostedRemaining.map { "\($0) name\($0 == 1 ? "" : "s") left this month" }
        let hosted = hostedProblem.map { EngineStatus(name: onDevice, detail: $0) }
            ?? EngineStatus(name: hostedName, detail: left ?? "Pro, \(onDevice) if offline", shownDetail: left ?? "\(onDevice) if offline")
        switch config.backend {
        case "claude":
            if !hasCredential { return EngineStatus(name: "Apple Vision", detail: "Claude has no key") }
            return claudeProblem.map { EngineStatus(name: "Apple Vision", detail: $0) } ?? claude
        case "hosted": return hasLicense ? hosted : EngineStatus(name: "Apple Vision", detail: "no Pro license")
        case "vision": return EngineStatus(name: "Apple Vision", detail: nil)
        case "apple": return appleReady ? EngineStatus(name: "Apple Intelligence", detail: nil) : EngineStatus(name: "Apple Vision", detail: "Apple Intelligence unavailable")
        default:
            let claudeProblem = config.claudeInAuto && hasCredential ? claudeProblem : nil
            if config.claudeInAuto && hasCredential && claudeProblem == nil { return claude }
            if config.claudeInAuto && hasLicense { return hosted }
            if config.claudeInAuto, let left = trialRemaining {
                return hostedProblem.map { EngineStatus(name: onDevice, detail: $0) }
                    ?? EngineStatus(name: hostedName, detail: "free trial, \(left) name\(left == 1 ? "" : "s") left")
            }
            if appleReady { return EngineStatus(name: "Apple Intelligence", detail: claudeProblem) }
            return EngineStatus(name: "Apple Vision", detail: claudeProblem)
        }
    }

    /// Hosted naming's `name`, kept for `status --json`. People see `hostedTitle`.
    public static let hostedName = "Hosted (Pro)"
    public static let hostedTitle = "Pro naming"

    /// An engine `name` (or `status --json`'s `engine.active`) as people see it.
    public static func title(_ name: String) -> String { name == hostedName ? hostedTitle : name }

    /// The free trial's names left when `auto` would use it: `pro_trial` on, no Pro, not used up.
    public static func trialRemaining(config: Config, trial: TrialState?, isPro: Bool) -> Int? {
        guard config.proTrial, !isPro, trial?.usedUp != true else { return nil }
        return trial?.remaining ?? TrialStore.names
    }

    /// What names photos while Claude's credential is rejected, after `ClaudeAuth.Problem.message`.
    public var untilClaudeWorks: String {
        isHosted ? "Until then, Pro naming names your photos." : "Until then, photos are named on this Mac with \(title)."
    }

    /// Hosted naming is what names the next photo.
    public var isHosted: Bool { name == Self.hostedName }

    /// A cloud engine (Claude, or hosted naming) names the next photo, and so PDFs too
    /// (`Backends.resolveDocuments` picks the same one).
    public var isCloud: Bool { isHosted || isClaude }

    /// What hosted naming sends and keeps (site/public/privacy/ says the same, in full). Shown
    /// when activating Pro turns it on (Settings → Pro, `license activate`) and under "Now using".
    public static let hostedNotice = "Pro naming sends a smaller copy of each photo, with GPS and other hidden data removed, "
        + "to BetterAirdrop's server and on to Anthropic's Claude. Its date, city, camera model and any text in it go too. "
        + "The server keeps no photos or names. To keep photos on this Mac, choose Apple Vision in Settings → Naming."

    /// Added to the notice when a cloud engine names PDFs too (Pro, "Name PDFs too").
    public static let pdfNotice = "For PDFs, only some of the text is sent, never the file."

    /// What to show under "Now using" and when Pro is activated: `hostedNotice` for hosted naming,
    /// plus `pdfNotice` when `namesPDFs` and the engine is a cloud one. Nil when there's nothing to say.
    public func notice(namesPDFs: Bool) -> String? {
        let parts = [isHosted ? Self.hostedNotice : nil, namesPDFs && isCloud ? Self.pdfNotice : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "claude-haiku-4-5" → "Claude Haiku 4.5". Unknown IDs are shown as they are.
    public static func modelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "claude" else { return id }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && Int($0) != nil }.joined(separator: ".")
        return "Claude \(family)" + (version.isEmpty ? "" : " \(version)")
    }
}

/// What the app says about the free Pro naming trial. Plain words: the copy pass calls hosted naming "Pro naming".
public enum ProTrial {
    /// The offer, in the menu on first run and in Settings → Naming. Opt-in: nothing is sent until "Try It".
    public static let offer = "Try Pro naming free on your next \(TrialStore.names) photos."
    /// The one-line notice that goes with the offer and the switch.
    public static let notice = "A smaller copy of each photo goes to BetterAirdrop's server and on to Anthropic, which names it."
    /// The upsell, once the trial is used up (menu, notification, Settings).
    public static let ended = "Your \(TrialStore.names) free Pro names are used up."
    public static let keep = "Keep names like these: $19"

    /// The menu's offer row: a new user with no Pro and no Claude key, on Automatic, who hasn't
    /// answered the offer or started the trial.
    public static func shouldOffer(config: Config, isPro: Bool, hasCredential: Bool, trial: TrialState?, dismissed: Bool) -> Bool {
        !isPro && !hasCredential && config.backend == "auto" && config.claudeInAuto && !config.proTrial && trial == nil && !dismissed
    }

    /// The line under Settings → Naming's switch.
    public static func settingsLine(config: Config, trial: TrialState?) -> String {
        if trial?.usedUp == true { return ended }
        guard config.proTrial else { return offer + " " + notice }
        let left = trial?.remaining ?? TrialStore.names
        return "\(left) of \(TrialStore.names) free names left. " + notice
    }
}
