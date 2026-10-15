import Foundation

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
    /// else vision. Claude and Apple Intelligence always fall back to Vision per photo on any
    /// failure, so a rename never fails because of the network or the model. An explicit backend
    /// that isn't available is an error.
    public static func resolve(_ id: String, config: Config = Config(), auth: ClaudeAuth = .shared,
                               apple: AppleFMNamer = AppleFMNamer()) throws -> any Namer {
        if id == "auto" {
            if case .ready = apple.availability() { return FallbackNamer(primary: apple, fallback: VisionNamer()) }
            if config.claudeInAuto, auth.resolve() != nil {
                return FallbackNamer(primary: ClaudeNamer(model: config.claudeModel, auth: auth), fallback: VisionNamer())
            }
            return VisionNamer()
        }
        let namer = id == "apple" ? apple : try make(id, config: config, auth: auth)
        if case .unavailable(let why) = namer.availability() { throw BackendError.unavailable(id, reason: why) }
        if id == "claude" || id == "apple" { return FallbackNamer(primary: namer, fallback: VisionNamer()) }
        return namer
    }

    /// True if this namer sends anything off the Mac.
    public static func isCloud(_ namer: any Namer) -> Bool { namer.id == "claude" }
}

/// The one-time notice shown the first time a cloud backend runs on this Mac.
public enum CloudNotice {
    public static let text = """
    BetterAirdrop is naming photos with Claude (Anthropic's API). For each photo it sends a 768 px JPEG
    with all metadata removed (no EXIF, no GPS), plus the capture date, the city name, the detected
    kind and a short snippet of text found in the image. Coordinates and file names stay on this Mac.
    To keep everything on-device, set `backend = "vision"` (or `[claude] auto = false`) in
    ~/.config/betterairdrop/config.toml. If Claude can't be reached, BetterAirdrop names the photo with Apple Vision.
    """

    static var marker: URL { Paths.supportDirectory.appendingPathComponent("cloud-notice-shown") }

    /// Calls `show` once per Mac (per betterairdrop state directory), then never again.
    public static func showOnce(_ show: (String) -> Void) {
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        show(text)
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data(Journal.timestamp().utf8))
    }
}
