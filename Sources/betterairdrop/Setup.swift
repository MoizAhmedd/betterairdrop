import ArgumentParser
import BetterAirdropCore
import BetterAirdropKit
import Foundation

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set BetterAirdrop up from Terminal, without the app's windows (for scripts and AI agents).",
        discussion: """
        Writes the same config the app's Settings do, stores the Claude key, and records that setup \
        is done. The app's first launch then only shows what a person has to click: macOS's \
        Downloads prompt and, if notifications are on, the notifications prompt.

        The key comes from an environment variable or stdin, never an argument:
          betterairdrop setup --engine auto --api-key-env ANTHROPIC_API_KEY --yes
          printf %s "$KEY" | betterairdrop setup --api-key-stdin --yes

        Then check with `betterairdrop status --json`. Running setup again changes only what you pass.
        """
    )

    @Option(help: ArgumentHelp("Naming engine: auto, claude, vision or apple. Default: leave as is (auto on a new install).", valueName: "engine"))
    var engine: String?

    @Option(name: .customLong("api-key-env"), help: ArgumentHelp("Store the Anthropic API key held in this environment variable.", valueName: "VAR"))
    var apiKeyEnv: String?

    @Flag(name: .customLong("api-key-stdin"), help: "Read the Anthropic API key from standard input.")
    var apiKeyStdin = false

    @Flag(name: .customLong("no-verify"), help: "Store the key without checking it with Anthropic (offline).")
    var noVerify = false

    @Flag(inversion: .prefixedNo, help: "Open BetterAirdrop when you log in. Default: on at the app's first launch.")
    var launchAtLogin: Bool?

    @Flag(inversion: .prefixedNo, help: "A notification after each batch, with Undo. Default: on.")
    var notify: Bool?

    @Flag(inversion: .prefixedNo, help: "Open the app when done, so macOS asks for Downloads access.")
    var open = true

    @Flag(name: .shortAndLong, help: "Apply without asking. Needed when stdin isn't a terminal.")
    var yes = false

    func run() throws {
        var request = SetupRequest(engine: engine?.lowercased(), apiKeyEnv: apiKeyEnv, launchAtLogin: launchAtLogin, notify: notify)
        if apiKeyStdin { request.apiKeyFromStdin = readLine(strippingNewline: true) ?? "" }

        let configURL = Config.defaultPath
        let config: Config
        do { config = try Config.load(from: configURL) } catch { fail("can't read \(tilde(configURL.path)): \(error)") }
        let store = CredentialStore()
        let apple: String? = { if case .unavailable(let why) = AppleFMNamer().availability() { return why }; return nil }()
        let context = SetupContext(config: config, environment: ProcessInfo.processInfo.environment,
                                   storedKey: store.hasAPIKey(), antLoggedIn: ClaudeAuth.shared.antToken() != nil,
                                   appleUnavailable: apple)
        let plan: SetupPlan
        do { plan = try SetupPlan.make(request, context) } catch { fail("\(error)") }

        print(plan.changes.isEmpty ? "No settings to change." : "BetterAirdrop setup:")
        for c in plan.changes { print("  · \(c)") }
        if !yes {
            guard isatty(STDIN_FILENO) == 1, !apiKeyStdin else { fail("nothing changed. Pass --yes to apply without a prompt.") }
            print("Apply? [Y/n] ", terminator: "")
            if readLine()?.lowercased().hasPrefix("n") == true { print("Nothing changed."); return }
        }

        if let key = plan.keyToStore {
            if !noVerify {
                switch ClaudeAuth.validate(key: key) {
                case .valid: break
                case .rejected(let why): fail("the key wasn't stored: \(why)")
                case .unreachable(let why): fail("couldn't check the key with Anthropic (\(why)). Nothing was changed; --no-verify stores it unchecked.")
                }
            }
            do { try store.storeAPIKey(key) } catch { fail("couldn't store the key: \(error.localizedDescription)") }
            ClaudeAuth.shared.invalidate()
        }
        if plan.config != config {
            do { try plan.config.save(to: configURL) } catch { fail("couldn't write \(tilde(configURL.path)): \(error)") }
        }

        let app = Uninstall.findApp()
        if let on = plan.launchAtLogin {
            if let app {
                if !Self.setLoginItem(on, app: app) { stderr("note: couldn't change the login item; the app's Settings → General can.") }
            } else {
                stderr("note: BetterAirdrop.app wasn't found, so the login item is left for its first launch.")
            }
        }
        var record = SetupRecord.load() ?? SetupRecord()
        record.completedAt = Date()
        if let on = plan.launchAtLogin { record.launchAtLogin = on }
        do { try record.save() } catch { fail("couldn't write \(tilde(SetupRecord.defaultURL.path)): \(error)") }

        for n in plan.notes { print("note: \(n)") }
        AppSignal.reload.post()   // a running app picks up the new config and key

        guard let app else {
            print("Done. Install the app next: curl -fsSL https://betterairdrop.com/install | sh")
            return
        }
        if let s = AppState.load(), Status.isApp(pid: s.pid) {
            print("Done. The running app has the new settings.")
        } else if Status.appRunning() {
            print("Done. Quit BetterAirdrop and open it again to use the new settings.")   // too old to listen
        } else if open {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [app.path]
            try p.run()
            p.waitUntilExit()
            print("Done. BetterAirdrop is open in the menu bar.")
        } else {
            print("Done. Open the app to start: open '\(app.path)'")
        }
        print("Check with `betterairdrop status --json`; its next_steps say what a person still has to click.")
    }

    /// SMAppService only acts for the app calling it, so the app binary does it (`--login-item on|off`).
    static func setLoginItem(_ on: Bool, app: URL) -> Bool {
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/BetterAirdrop")
        p.arguments = ["--login-item", on ? "on" : "off"]
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// Prints `error: …` and exits 2 (no usage text: these aren't typos).
func fail(_ message: String) -> Never {
    fflush(stdout)
    stderr("error: \(message)")
    Darwin.exit(2)
}
