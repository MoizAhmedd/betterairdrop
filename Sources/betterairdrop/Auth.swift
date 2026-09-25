import BetterAirdropCore
import ArgumentParser
import Foundation

struct Auth: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up the Claude backend's credential.",
        discussion: """
        betterairdrop looks for a credential in this order:
          1. ANTHROPIC_API_KEY in the environment
          2. an API key stored by `betterairdrop auth claude` (or the app) in
             ~/Library/Application Support/betterairdrop/credentials, readable only by you
          3. the Anthropic CLI's login (`ant auth login`), used as an OAuth bearer token
        Secrets are never printed or logged.
        """,
        subcommands: [Claude.self, Status.self, Login.self, Logout.self]
    )

    struct Claude: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Store an Anthropic API key for BetterAirdrop (hidden prompt, or piped on stdin).")

        @Flag(help: "Remove the stored key instead.")
        var remove = false

        func run() throws {
            if remove {
                print(Self.remove() ? "Removed the stored API key." : "No API key was stored.")
                return
            }
            let key: String
            if isatty(STDIN_FILENO) == 1 {
                var buf = [CChar](repeating: 0, count: 512)
                guard let p = readpassphrase("Anthropic API key (input hidden): ", &buf, buf.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) else {
                    throw ValidationError("couldn't read the key")
                }
                key = String(cString: p)
                buf.withUnsafeMutableBufferPointer { b in for i in b.indices { b[i] = 0 } }
            } else {
                key = readLine(strippingNewline: true) ?? ""
            }
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { throw ValidationError("no key entered") }
            guard k.hasPrefix("sk-ant-"), !k.contains(" ") else {
                throw ValidationError("that doesn't look like an Anthropic API key (they start with sk-ant-)")
            }
            let store = CredentialStore()
            try store.storeAPIKey(k)
            print("Stored in \(store.file.path) (readable only by you). `betterairdrop auth status` shows which credential is used.")
        }

        /// The key file, plus a pre-0.3 Keychain item if one is left.
        static func remove() -> Bool {
            let file = CredentialStore(legacy: .none).deleteAPIKey()
            let keychain = Keychain.deleteAPIKey()
            return file || keychain
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which credential the Claude backend would use (never prints it).")

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let auth = ClaudeAuth.shared
            for (i, (source, state)) in auth.report().enumerated() {
                print("  \(i + 1). \(source.rawValue.padding(toLength: 32, withPad: " ", startingAt: 0)) \(state)")
            }
            let config = try global.loadConfig()
            if let c = auth.resolve() {
                print("Claude would use: \(c.source.rawValue)  (model \(config.claudeModel))")
                let auto = config.backend == "auto" && config.claudeInAuto
                print("Backend: \(config.backend)\(auto ? " → Claude names photos, Apple Vision is the fallback" : config.backend == "claude" ? "" : " (Claude is used only with --backend claude)")")
            } else {
                print("No credential found: `backend = auto` uses Apple Vision (on-device).")
                print("Set one up with `betterairdrop auth claude` (API key) or `betterairdrop auth login` (Anthropic CLI).")
            }
        }
    }

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Log in with the Anthropic CLI (`ant auth login`, opens a browser).")

        func run() throws {
            guard let ant = ClaudeAuth.shared.antExecutable else {
                print("""
                The Anthropic CLI (`ant`) isn't installed. Install it, then run this again:
                    brew install anthropics/tap/ant
                Or store an API key instead: betterairdrop auth claude
                """)
                throw ExitCode(1)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ant)
            p.arguments = ["auth", "login"]
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw ExitCode(p.terminationStatus) }
        }
    }

    struct Logout: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the API key stored by `betterairdrop auth claude` (the ant login is left alone).")
        func run() throws {
            print(Claude.remove() ? "Removed the stored API key." : "No API key was stored.")
        }
    }
}
