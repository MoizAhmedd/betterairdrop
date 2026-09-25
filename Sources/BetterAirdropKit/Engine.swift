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
    public static func current(config: Config, hasCredential: Bool, appleReady: Bool = false) -> EngineStatus {
        let claude = EngineStatus(name: modelName(config.claudeModel), detail: "Vision if offline")
        switch config.backend {
        case "claude": return hasCredential ? claude : EngineStatus(name: "Apple Vision", detail: "Claude has no key")
        case "vision": return EngineStatus(name: "Apple Vision", detail: nil)
        case "apple": return appleReady ? EngineStatus(name: "Apple Intelligence", detail: nil) : EngineStatus(name: "Apple Vision", detail: "Apple Intelligence unavailable")
        default:
            if appleReady { return EngineStatus(name: "Apple Intelligence", detail: nil) }
            if config.claudeInAuto && hasCredential { return claude }
            return EngineStatus(name: "Apple Vision", detail: nil)
        }
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
