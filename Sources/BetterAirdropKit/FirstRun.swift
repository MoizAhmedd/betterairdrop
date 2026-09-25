import BetterAirdropCore
import Foundation

/// Reads `ANTHROPIC_API_KEY` from the user's login shell, the way VS Code resolves the shell
/// environment: apps opened from Finder or by Homebrew don't inherit what `~/.zshrc` exports.
/// The value is only returned, never logged or written.
public enum ShellKey {
    static let begin = "__BETTERAIRDROP_KEY_BEGIN__"
    static let end = "__BETTERAIRDROP_KEY_END__"
    public static let timeout: TimeInterval = 3

    /// `$SHELL` if it's an absolute path to an executable, else zsh (the macOS default).
    public static func shell(environment: [String: String]) -> String {
        if let s = environment["SHELL"], s.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: s) { return s }
        return "/bin/zsh"
    }

    /// An interactive login shell prints the key between markers, so banners from rc files are ignored.
    public static var arguments: [String] {
        ["-ilc", "printf '%s%s%s' '\(begin)' \"$ANTHROPIC_API_KEY\" '\(end)'"]
    }

    public static func parse(_ output: String) -> String? {
        guard let b = output.range(of: begin, options: .backwards),
              let e = output.range(of: end, range: b.upperBound..<output.endIndex) else { return nil }
        let key = output[b.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return key
    }

    /// Synchronous and up to `timeout` long: call it off the main thread.
    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment,
                            run: (String, [String], TimeInterval) -> String? = { ShellKey.run($0, $1, timeout: $2) }) -> String? {
        run(shell(environment: environment), arguments, timeout).flatMap(parse)
    }

    /// Runs a command, returning stdout, or nil on failure or timeout. An interactive shell ignores
    /// SIGTERM, so a slow one is killed outright.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        let box = Box()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { box.data = out.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            return nil
        }
        // A background job the rc file started can hold the pipe open; don't wait on it forever.
        guard read.wait(timeout: .now() + 0.5) == .success, p.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }

    final class Box: @unchecked Sendable { var data = Data() }
}

/// When the app offers a key found in the shell, and when it shows "Better names: add a Claude key".
public enum KeyOffer {
    public static func shouldLookInShell(hasCredential: Bool, backend: String, declined: Bool) -> Bool {
        !hasCredential && backend != "vision" && !declined
    }

    public static func showNudge(hasCredential: Bool, backend: String, offering: Bool) -> Bool {
        !hasCredential && backend != "vision" && !offering
    }
}

/// Unnamed camera files (IMG_4821.HEIC, PXL_…, DSC_…) already sitting in a folder, for the
/// first-run preview. Unlike the watcher, this doesn't require AirDrop's "downloaded by" tag:
/// nothing is renamed until the user clicks Rename in the preview.
public enum CameraFiles {
    private static let patterns: [NSRegularExpression] = [
        #"^IMG_E?\d{3,}(_\d{6,9})?"#,          // iPhone, Android IMG_20260921_184512
        #"^PXL_\d{8}_\d{6,}"#,                 // Pixel
        #"^MVIMG_\d{8}_\d{6}"#,
        #"^_?DSC[NF_]?\d{3,}"#,                // Nikon, Sony, Fujifilm
        #"^DJI_\d{3,}"#, #"^GOPR\d{3,}"#,
        #"^\d{8}_\d{6}"#,                      // Samsung
    ].map { try! NSRegularExpression(pattern: $0 + #"( ?\(\d+\)| \d+|-\d+|~\d+|-edited)*$"#, options: [.caseInsensitive]) }

    public static func isCameraName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard Planner.imageExtensions.contains(ext) else { return false }
        let stem = (name as NSString).deletingPathExtension
        let range = NSRange(stem.startIndex..., in: stem)
        return patterns.contains { $0.firstMatch(in: stem, range: range) != nil }
    }

    /// Top level only, newest first.
    public static func find(in folder: URL, limit: Int? = nil) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        let files = items.compactMap { u -> (URL, Date)? in
            guard isCameraName(u.lastPathComponent),
                  let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (u, v.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }.map(\.0)
        return limit.map { Array(files.prefix($0)) } ?? files
    }
}

/// The preview names at most `batchSize` photos at a time, so opening it never costs much.
public enum PreviewCost {
    public static let batchSize = 20
    /// Claude Haiku, a 1024 px photo: about $2 per 1,000 (docs/spikes.md).
    public static let claudePerPhoto = 0.002

    public static func text(count: Int, claude: Bool) -> String {
        guard claude else { return "free, on this Mac" }
        let usd = Double(count) * claudePerPhoto
        return usd < 0.01 ? "under $0.01" : String(format: "~$%.2f", usd)
    }
}
