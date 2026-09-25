import BetterAirdropCore
import ArgumentParser
import Foundation

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch a folder for AirDropped photos and name them as they arrive.",
        discussion: """
        Only files AirDrop delivered (quarantine agent sharingd) that arrive after the watcher starts are
        touched; pass --backlog to also name earlier AirDrops. Each batch gets one notification and one
        undo: `betterairdrop undo` (last batch) or `betterairdrop undo --batch ID`.
        --foreground runs in this Terminal window, which already has access to Downloads. The background
        LaunchAgent (`betterairdrop install`) comes later.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Run in this terminal until Ctrl-C (currently the only mode).")
    var foreground = false

    @Option(help: "Folder to watch (default: watch.folder in the config, ~/Downloads).", completion: .directory)
    var dir: String?

    @Option(help: "Naming backend: auto, claude, vision, apple (macOS 27).")
    var backend: String?

    @Flag(help: "Also name AirDrops that arrived before the watcher started.")
    var backlog = false

    @Flag(help: "Process one batch (or nothing) and exit.")
    var once = false

    @Flag(help: "Don't post macOS notifications.")
    var noNotify = false

    @Option(help: .hidden) var quietSeconds: Double?

    func run() throws {
        guard foreground || once else {
            throw ValidationError("The background agent isn't available yet. Run `betterairdrop watch --foreground` in Terminal.")
        }
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so `| tee log.txt` shows batches as they happen
        let config = try global.loadConfig()
        let folder = URL(fileURLWithPath: ((dir ?? config.watchFolder) as NSString).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw ValidationError("no such folder: \(folder.path)")
        }
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil else {
            throw ValidationError("can't read \(tilde(folder.path)): give your terminal access in System Settings → Privacy & Security → Files and Folders")
        }
        guard let lock = ProcessLock() else {
            throw ValidationError("another betterairdrop watcher is already running")
        }
        defer { withExtendedLifetime(lock) {} }   // hold the lock until the watcher exits

        let planner = try makePlanner(config: config, backend: backend)
        let committer = Committer(config: config)
        let namer = planner.namer
        committer.backend = namer?.id ?? "none"
        var options = Watcher.Options(folder: folder)
        options.airdropOnly = config.watchAirdropOnly
        options.backlog = backlog
        if let q = quietSeconds { options.quietWindow = q }
        let watcher = Watcher(options: options, planner: planner, committer: committer)
        let notify = config.watchNotify && !noNotify
        watcher.log = { print("  · \($0)") }
        watcher.onBatch = { b in
            print("[\(Self.clock())] batch \(b.id)")
            for o in b.outcomes {
                let src = (o.source as NSString).lastPathComponent
                switch o.status {
                case .done: print("  ✓ \(src)  →  \(((o.target ?? "") as NSString).lastPathComponent)")
                case .skipped: print("  – \(src)  (\(o.message ?? "skipped"))")
                case .failed: print("  ✗ \(src)  \(o.message ?? "")")
                }
            }
            reportFallbacks(b.proposals)
            let summary = Watcher.summary(b)
            let tokens = b.proposals.filter { ($0.source as NSString).pathExtension.lowercased() != "mov" }.compactMap { $0.suggestion?.usage }
            let cost = tokens.reduce(0) { $0 + $1.cost() }
            print("\(summary). Undo: betterairdrop undo --batch \(b.id)\(tokens.isEmpty ? "" : String(format: "  (Claude: %d photo%@, about $%.4f)", tokens.count, tokens.count == 1 ? "" : "s", cost))")
            if notify { Notifier.post(title: "betterairdrop", message: "\(summary) · undo: betterairdrop undo") }
        }

        let backendDesc = namer.map { Backends.isCloud($0) ? "claude (Apple Vision if it fails)" : $0.id } ?? "none"
        print("betterairdrop: watching \(tilde(folder.path)) for \(options.airdropOnly ? "AirDrop arrivals" : "new photos")"
              + "\(backlog ? " (including earlier ones)" : "") · backend \(backendDesc) · Ctrl-C to stop")

        if once { _ = watcher.runOnce(); return }

        signal(SIGINT, SIG_IGN)
        let stop = StopFlag()
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            if stop.isSet { Darwin.exit(130) }
            stop.set()
            FileHandle.standardError.write(Data("\nbetterairdrop: stopping after the current batch (Ctrl-C again to quit now)\n".utf8))
        }
        source.resume()
        watcher.run(shouldStop: { stop.isSet })
        print("betterairdrop: stopped.")
    }

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
}
