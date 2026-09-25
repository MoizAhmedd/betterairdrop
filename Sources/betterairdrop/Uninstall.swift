import BetterAirdropCore
import BetterAirdropKit
import ArgumentParser
import Foundation

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove BetterAirdrop: login item, Keychain key, CLI link, permissions and the app.",
        discussion: "Renamed photos stay renamed. With --purge, settings and the rename history are deleted too. This runs the same steps as Settings → Advanced → Uninstall… in the app."
    )

    @Flag(help: "Also delete ~/.config/betterairdrop and the rename history.")
    var purge = false

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    func run() throws {
        let app = Self.findApp()
        if !yes {
            print("This removes \(app.map { tilde($0.path) } ?? "BetterAirdrop's settings")"
                  + ", its login item, Keychain key, CLI link and Downloads permission\(purge ? ", plus your settings and rename history" : "").")
            print("Renamed photos stay renamed. Continue? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else { print("Nothing changed."); return }
        }
        if let app {
            // Run inside the app's identity so it can remove its own login item.
            let p = Process()
            p.executableURL = app.appendingPathComponent("Contents/MacOS/BetterAirdrop")
            p.arguments = ["--uninstall"] + (purge ? ["--purge"] : [])
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw ExitCode(p.terminationStatus) }
            return
        }
        // No app (a CLI-only build): the steps that don't need it.
        var u = Uninstaller()
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        u.cliLink = CLILink(target: exe)
        for s in u.uninstall(purge: purge) { print("\(s.ok ? "✓" : "✗") \(s.name)\(s.detail.map { ": \($0)" } ?? "")") }
    }

    /// The app this CLI lives in, else the usual install locations.
    static func findApp() -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" { return bundle }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for c in [home.appendingPathComponent("Applications/BetterAirdrop.app"), URL(fileURLWithPath: "/Applications/BetterAirdrop.app")]
        where FileManager.default.fileExists(atPath: c.path) { return c }
        return nil
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether the app (or a Terminal watcher) is renaming AirDrops, and this month's totals.")

    @OptionGroup var global: GlobalOptions

    func run() throws {
        let config = try global.loadConfig()
        if let owner = ProcessLock.holder() {
            let who = owner.kind == .app ? "The BetterAirdrop app" : "`betterairdrop watch` (pid \(owner.pid))"
            print("\(who) is watching \(tilde(owner.folder.isEmpty ? config.watchFolder : owner.folder)).")
        } else if Self.appRunning() {
            print("The BetterAirdrop app is running but not watching (paused, or waiting for folder access).")
        } else {
            print("Nothing is watching for AirDrops. Open BetterAirdrop, or run `betterairdrop watch --foreground`.")
        }
        let journal = Journal()
        let month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        let stats = journal.stats(since: month)
        print("This month: \(stats.photos) photo\(stats.photos == 1 ? "" : "s") renamed" + (stats.costUSD > 0 ? String(format: ", Claude ≈ $%.2f", stats.costUSD) : "") + ".")
        if let last = journal.recentBatches(limit: 1).first {
            print("Last batch: \(last.id) (\(last.entries.count) file\(last.entries.count == 1 ? "" : "s")). Undo with `betterairdrop undo`.")
        }
        print("Backend: \(config.backend). Config: \(tilde(Config.defaultPath.path)).")
    }

    static func appRunning() -> Bool {
        let out = ClaudeAuth.run("/bin/ps", ["-axo", "comm"], timeout: 5) ?? ""
        return out.split(separator: "\n").contains { $0.hasSuffix("BetterAirdrop.app/Contents/MacOS/BetterAirdrop") }
    }
}
