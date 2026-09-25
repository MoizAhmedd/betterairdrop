import AppKit

@main
enum BetterAirdropMain {
    static func main() {
        let args = CommandLine.arguments
        // Headless helpers used by scripts (no UI, no permissions touched).
        if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
            do { try Art.writeIconset(to: URL(fileURLWithPath: args[i + 1])); exit(0) } catch { print(error); exit(1) }
        }
        if args.contains("--uninstall") { exit(Headless.uninstall(purge: args.contains("--purge"))) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
