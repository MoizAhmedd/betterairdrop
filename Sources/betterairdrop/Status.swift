import ArgumentParser
import BetterAirdropCore
import BetterAirdropKit
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether AirDrops are being renamed, what's missing, and this month's totals.",
        discussion: """
        --json is for scripts and AI agents: `ready` is true once AirDrops are being renamed, and \
        `next_steps` lists what's left, marked "human" for clicks only a person can make (macOS \
        permission prompts) and "agent" for things a command can do. Permissions are as the app \
        last reported them: macOS grants them per app, so this command can't check them itself.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Print JSON (see docs/install-for-agents.md for the fields).")
    var json = false

    func run() throws {
        let config = try global.loadConfig()
        let report = Self.report(config: config)
        if json { print(try report.json()); return }

        if let owner = ProcessLock.holder() {
            let who = owner.kind == .app ? "The BetterAirdrop app" : "`betterairdrop watch` (pid \(owner.pid))"
            print("\(who) is watching \(tilde(owner.folder.isEmpty ? config.watchFolder : owner.folder)).")
        } else if report.app.running {
            print("The BetterAirdrop app is running but not watching (paused, or waiting for folder access).")
        } else {
            print("Nothing is watching for AirDrops. Open BetterAirdrop, or run `betterairdrop watch --foreground`.")
        }
        let p = report.permissions
        if p.reportedAt != nil {
            print("Folder access: \(p.folderAccess.replacingOccurrences(of: "_", with: " ")) · notifications: \(p.notifications.replacingOccurrences(of: "_", with: " ")) · open at login: \(p.loginItem.replacingOccurrences(of: "_", with: " ")).")
        }
        let journal = Journal()
        let month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        let stats = journal.stats(since: month)
        print("This month: \(stats.photos) photo\(stats.photos == 1 ? "" : "s") renamed" + (stats.costUSD > 0 ? String(format: ", Claude ≈ $%.2f", stats.costUSD) : "") + ".")
        if let last = journal.recentBatches(limit: 1).first {
            print("Last batch: \(last.id) (\(last.entries.count) file\(last.entries.count == 1 ? "" : "s")). Undo with `betterairdrop undo`.")
        }
        print("Backend: \(config.backend) (\(report.engine.active)). Config: \(tilde(Config.defaultPath.path)).")
        for s in report.nextSteps {
            print("\(s.who == "human" ? "Needs you" : "To do")\(s.required ? "" : " (optional)"): \(s.text)\(s.command.map { "  → \($0)" } ?? "")")
        }
    }

    static func report(config: Config) -> StatusReport {
        let app = Uninstall.findApp()
        var state = AppState.load()
        var running = state.map { isApp(pid: $0.pid) } ?? false
        if !running { running = appRunning() }
        if running, let before = state {
            // Ask the app for a fresh report (it re-checks its permissions), and wait briefly for it.
            // Compared whole: updated_at has whole seconds, so a report in the same second ties.
            AppSignal.report.post()
            let end = Date().addingTimeInterval(1.5)
            while Date() < end {
                Thread.sleep(forTimeInterval: 0.1)
                if let s = AppState.load(), s != before { state = s; break }
            }
        }
        let version = app.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        return StatusReport.make(.init(
            cliVersion: BetterAirdropVersion.current, appPath: app?.path, appVersion: version, appRunning: running,
            appState: state, setup: SetupRecord.load(), config: config,
            storedKey: CredentialStore().hasAPIKey(), antLoggedIn: ClaudeAuth.shared.antToken() != nil,
            lockHolder: ProcessLock.holder(), appleReady: AppleIntelligenceStatus.current.isAvailable,
            license: LicenseStore().read()))
    }

    static func isApp(pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0 && LockHolder.processName(pid) == "BetterAirdrop"
    }

    static func appRunning() -> Bool {
        let out = ClaudeAuth.run("/bin/ps", ["-axo", "comm"], timeout: 5) ?? ""
        return out.split(separator: "\n").contains { $0.hasSuffix("BetterAirdrop.app/Contents/MacOS/BetterAirdrop") }
    }
}
