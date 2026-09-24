import AirnameCore
import ArgumentParser
import Foundation

struct Auth: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up the Claude backend's credential.",
        discussion: """
        airname looks for a credential in this order:
          1. ANTHROPIC_API_KEY in the environment
          2. an API key stored in the Keychain by `airname auth claude`
          3. the Anthropic CLI's login (`ant auth login`), used as an OAuth bearer token
        Secrets are never printed, logged or written to disk by airname.
        """,
        subcommands: [Claude.self, Status.self, Login.self, Logout.self]
    )

    struct Claude: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Store an Anthropic API key in the Keychain (hidden prompt, or piped on stdin).")

        @Flag(help: "Remove the stored key instead.")
        var remove = false

        func run() throws {
            if remove {
                print(Keychain.deleteAPIKey() ? "Removed the API key from the Keychain." : "No API key was stored.")
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
            try Keychain.storeAPIKey(k)
            print("Stored in the Keychain (service \(Keychain.service)). `airname auth status` shows which credential is used.")
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
                print("Set one up with `airname auth claude` (API key) or `airname auth login` (Anthropic CLI).")
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
                Or store an API key instead: airname auth claude
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
        static let configuration = CommandConfiguration(abstract: "Remove the API key stored by `airname auth claude` (the ant login is left alone).")
        func run() throws {
            print(Keychain.deleteAPIKey() ? "Removed the API key from the Keychain." : "No API key was stored.")
        }
    }
}
