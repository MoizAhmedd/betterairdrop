import BetterAirdropCore
import Foundation

/// What the app shows about the naming engine ("Claude Haiku", "Apple Vision"…).
public enum EngineChoice: String, CaseIterable, Sendable {
    case auto, apple, claude, vision

    public var title: String {
        switch self {
        case .auto: "Automatic (recommended)"
        case .apple: "Apple Intelligence"
        case .claude: "Claude Haiku"
        case .vision: "Apple Vision"
        }
    }
}

public struct EngineStatus: Equatable, Sendable {
    /// The engine that will name the next photo.
    public var name: String
    /// e.g. "Vision if offline".
    public var detail: String?

    /// `hasCredential`: a Claude credential resolves (key, env or `ant`). `appleReady`: Foundation Models is usable.
    /// `hasLicense`: Pro is active or in grace on this Mac (hosted naming). `hostedProblem`: why
    /// hosted naming is being skipped right now (`HostedNamer.currentProblem`), e.g. its monthly
    /// limit. `hostedRemaining`: names left this month, as the server last said.
    /// `auto` follows `Backends.resolve`: Claude, hosted, Apple Intelligence, Vision.
    public static func current(config: Config, hasCredential: Bool, appleReady: Bool = false,
                               hasLicense: Bool = false, hostedProblem: String? = nil, hostedRemaining: Int? = nil) -> EngineStatus {
        let claude = EngineStatus(name: modelName(config.claudeModel), detail: "Vision if offline")
        // Hosted falls back to Apple Intelligence when it's ready, else Vision (Backends.onDevice).
        let onDevice = appleReady ? "Apple Intelligence" : "Apple Vision"
        let hosted = hostedProblem.map { EngineStatus(name: onDevice, detail: $0) }
            ?? EngineStatus(name: hostedName, detail: hostedRemaining.map { "\($0) name\($0 == 1 ? "" : "s") left this month" }
                                                ?? "Pro, \(onDevice) if offline")
        switch config.backend {
        case "claude": return hasCredential ? claude : EngineStatus(name: "Apple Vision", detail: "Claude has no key")
        case "hosted": return hasLicense ? hosted : EngineStatus(name: "Apple Vision", detail: "no Pro license")
        case "vision": return EngineStatus(name: "Apple Vision", detail: nil)
        case "apple": return appleReady ? EngineStatus(name: "Apple Intelligence", detail: nil) : EngineStatus(name: "Apple Vision", detail: "Apple Intelligence unavailable")
        default:
            if config.claudeInAuto && hasCredential { return claude }
            if config.claudeInAuto && hasLicense { return hosted }
            if appleReady { return EngineStatus(name: "Apple Intelligence", detail: nil) }
            return EngineStatus(name: "Apple Vision", detail: nil)
        }
    }

    public static let hostedName = "Hosted (Pro)"

    /// "claude-haiku-4-5" → "Claude Haiku 4.5". Unknown IDs are shown as they are.
    public static func modelName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "claude" else { return id }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && Int($0) != nil }.joined(separator: ".")
        return "Claude \(family)" + (version.isEmpty ? "" : " \(version)")
    }
}
