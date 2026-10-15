import BetterAirdropCore
import BetterAirdropKit
import ArgumentParser
import Foundation

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove BetterAirdrop: login item, stored API key, CLI link, permissions and the app.",
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
                  + ", its login item, stored API key, CLI link and Downloads permission\(purge ? ", plus your settings and rename history" : "").")
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
