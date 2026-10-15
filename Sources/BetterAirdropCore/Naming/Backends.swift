import Foundation

public enum BackendError: Error, CustomStringConvertible, Equatable {
    case unknown(String), unavailable(String, reason: String)
    public var description: String {
        switch self {
        case .unknown(let id): "unknown backend \"\(id)\" (choose auto, apple, vision, ollama, claude or hosted)"
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
    public static let ids = ["apple", "vision", "ollama", "claude", "hosted"]

    public static func make(_ id: String, config: Config = Config(), auth: ClaudeAuth = .shared,
                            license: any LicenseKeySource = NoLicenseKey()) throws -> any Namer {
        switch id {
        case "apple": AppleFMNamer()
        case "vision": VisionNamer()
        case "claude": ClaudeNamer(model: config.claudeModel, auth: auth)
        case "hosted": HostedNamer(baseURL: config.hostedURL, license: license)
        case "ollama": PlannedNamer(id: id)
        default: throw BackendError.unknown(id)
        }
    }

    /// `auto` = Claude with the user's own credential, else hosted naming if this Mac has a Pro
    /// license (both only while `claude.auto` is on), else Apple Intelligence if it's ready, else
    /// Vision. Each falls back per photo on any failure, so a rename never fails because of the
    /// network or the model: Claude and Apple Intelligence to Vision; hosted (Pro) to Apple
    /// Intelligence when it's ready, else Vision. Hosted is chosen whenever the license is there,
    /// even while it's over a limit, so it picks up again after the reset without a rebuild.
    /// An explicit backend that isn't available is an error. `license` is BetterAirdropKit's
    /// `LicenseStore` in the app and the CLI; without it there's no hosted naming.
    public static func resolve(_ id: String, config: Config = Config(), auth: ClaudeAuth = .shared,
                               apple: AppleFMNamer = AppleFMNamer(),
                               license: any LicenseKeySource = NoLicenseKey()) throws -> any Namer {
        if id == "auto" {
            if config.claudeInAuto, auth.resolve() != nil {
                return FallbackNamer(primary: ClaudeNamer(model: config.claudeModel, auth: auth), fallback: VisionNamer())
            }
            if config.claudeInAuto, license.licenseKey() != nil {
                return FallbackNamer(primary: HostedNamer(baseURL: config.hostedURL, license: license), fallback: onDevice(apple))
            }
            if case .ready = apple.availability() { return FallbackNamer(primary: apple, fallback: VisionNamer()) }
            return VisionNamer()
        }
        let namer = id == "apple" ? apple : try make(id, config: config, auth: auth, license: license)
        if case .unavailable(let why) = namer.availability() { throw BackendError.unavailable(id, reason: why) }
        if id == "hosted" { return FallbackNamer(primary: namer, fallback: onDevice(apple)) }
        if id == "claude" || id == "apple" { return FallbackNamer(primary: namer, fallback: VisionNamer()) }
        return namer
    }

    /// Hosted naming's fallback: Apple Intelligence (itself falling back to Vision) when it's ready, else Vision.
    static func onDevice(_ apple: AppleFMNamer) -> any Namer {
        if case .ready = apple.availability() { return FallbackNamer(primary: apple, fallback: VisionNamer()) }
        return VisionNamer()
    }

    /// True if this namer sends anything off the Mac.
    public static func isCloud(_ namer: any Namer) -> Bool { namer.id == "claude" || namer.id == "hosted" }
}

/// The one-time notice shown the first time a cloud backend runs on this Mac.
public enum CloudNotice {
    public static let text = """
    BetterAirdrop is naming photos with Claude (Anthropic's API): with your own key, or with
    BetterAirdrop Pro through BetterAirdrop's hosted-naming server, which also gets your Pro license
    key and keeps no photos, context or names. For each photo it sends a 768 px JPEG with all
    metadata removed (no EXIF, no GPS), plus text: the capture date, the city name, the camera model,
    the app that created it, the detected kind, on-device labels and a short snippet of text found
    in the image. Coordinates and file names stay on this Mac. To keep everything on-device, set
    `backend = "vision"` (or `[claude] auto = false`) in ~/.config/betterairdrop/config.toml. A photo
    Claude can't name is named on this Mac (Apple Vision; for hosted naming, Apple Intelligence if it's on).
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
