import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device Foundation Models (macOS 27 + Apple Intelligence). Placeholder until M4:
/// it compiles everywhere and reports why it isn't available. The FoundationModels branch is
/// only compiled with an SDK that ships the framework.
public struct AppleFMNamer: Namer {
    public let id = "apple"
    public init() {}

    public func availability() -> Availability {
        #if canImport(FoundationModels)
        if #available(macOS 27, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .unavailable("Foundation Models is available, but the apple backend isn't implemented yet (M4)")
            default: return .unavailable("Apple Intelligence is off or not supported on this Mac")
            }
        }
        #endif
        return .unavailable("requires macOS 27 with Apple Intelligence")
    }

    public func suggest(for url: URL, context: PhotoContext) throws -> NameSuggestion {
        throw BackendError.unavailable(id, reason: "not implemented yet (M4)")
    }
}

public enum BackendError: Error, CustomStringConvertible, Equatable {
    case unknown(String), unavailable(String, reason: String)
    public var description: String {
        switch self {
        case .unknown(let id): "unknown backend \"\(id)\" (choose auto, apple, vision, ollama or claude)"
        case .unavailable(let id, let reason): "backend \"\(id)\" is unavailable: \(reason)"
        }
    }
}

/// Opt-in backends that aren't built yet. Listed so `--backend` gives a clear answer.
struct PlannedNamer: Namer {
    let id: String
    func availability() -> Availability { .unavailable("not implemented yet") }
    func suggest(for url: URL, context: PhotoContext) throws -> NameSuggestion {
        throw BackendError.unavailable(id, reason: "not implemented yet")
    }
}

public enum Backends {
    public static let ids = ["apple", "vision", "ollama", "claude"]

    public static func make(_ id: String, config: Config = Config(), auth: ClaudeAuth = .shared) throws -> any Namer {
        switch id {
        case "apple": AppleFMNamer()
        case "vision": VisionNamer()
        case "claude": ClaudeNamer(model: config.claudeModel, auth: auth)
        case "ollama": PlannedNamer(id: id)
        default: throw BackendError.unknown(id)
        }
    }

    /// `auto` = apple if it's ready, else Claude if a credential resolves (and `claude.auto` is on),
    /// else vision. Claude always falls back to Vision per photo on any failure, so a rename never
    /// fails because of the network. An explicit backend that isn't available is an error.
    public static func resolve(_ id: String, config: Config = Config(), auth: ClaudeAuth = .shared) throws -> any Namer {
        if id == "auto" {
            let apple = AppleFMNamer()
            if case .ready = apple.availability() { return apple }
            if config.claudeInAuto, auth.resolve() != nil {
                return FallbackNamer(primary: ClaudeNamer(model: config.claudeModel, auth: auth), fallback: VisionNamer())
            }
            return VisionNamer()
        }
        let namer = try make(id, config: config, auth: auth)
        if case .unavailable(let why) = namer.availability() { throw BackendError.unavailable(id, reason: why) }
        if id == "claude" { return FallbackNamer(primary: namer, fallback: VisionNamer()) }
        return namer
    }

    /// True if this namer sends anything off the Mac.
    public static func isCloud(_ namer: any Namer) -> Bool { namer.id == "claude" }
}

/// The one-time notice shown the first time a cloud backend runs on this Mac.
public enum CloudNotice {
    public static let text = """
    airname is naming photos with Claude (Anthropic's API). For each photo it sends a 1024 px JPEG
    with all metadata removed (no EXIF, no GPS), plus the capture date, the city name, the detected
    kind and a short snippet of text found in the image. Coordinates and file names stay on this Mac.
    To keep everything on-device, set `backend = "vision"` (or `[claude] auto = false`) in
    ~/.config/airname/config.toml. If Claude can't be reached, airname names the photo with Apple Vision.
    """

    static var marker: URL { Paths.supportDirectory.appendingPathComponent("cloud-notice-shown") }

    /// Calls `show` once per Mac (per airname state directory), then never again.
    public static func showOnce(_ show: (String) -> Void) {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        show(text)
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data(Journal.timestamp().utf8))
    }
}
