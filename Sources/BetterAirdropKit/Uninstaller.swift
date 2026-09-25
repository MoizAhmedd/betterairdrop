import BetterAirdropCore
import Foundation

/// Settings → Advanced → Uninstall… and `betterairdrop uninstall` (UX-PROPOSAL §2.7). Renamed photos
/// stay renamed. Each step is injectable so the sequence is tested without touching the real Mac.
public struct Uninstaller {
    public struct Step: Equatable, Sendable {
        public var name: String
        public var ok: Bool
        public var detail: String?
    }

    public var bundleID = "dev.betterairdrop.app"
    public var cliLink: CLILink?
    public var supportDirectory = Paths.supportDirectory
    public var configDirectory = Config.defaultPath.deletingLastPathComponent()
    /// SMAppService.mainApp.unregister() (the app only).
    public var unregisterLoginItem: (() -> Bool)?
    public var deleteKeychainKey: () -> Bool = { Keychain.deleteAPIKey() }
    public var run: ([String]) -> Bool = { args in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    /// Moves the app to the Trash (the app only; runs last).
    public var recycleApp: (() -> Bool)?

    public init() {}

    public func uninstall(purge: Bool) -> [Step] {
        var steps: [Step] = []
        if let unregisterLoginItem { steps.append(Step(name: "Login item", ok: unregisterLoginItem())) }
        steps.append(Step(name: "Keychain key", ok: true, detail: deleteKeychainKey() ? "removed" : "none stored"))
        if let cliLink { steps.append(Step(name: "CLI link", ok: true, detail: cliLink.remove() ? "removed \(cliLink.link.path)" : "not installed")) }
        // tccutil finds the app through Launch Services, so this must run before the app is trashed.
        steps.append(Step(name: "Permissions", ok: run(["/usr/bin/tccutil", "reset", "All", bundleID])))
        if purge {
            let fm = FileManager.default
            for (name, dir) in [("Rename history", supportDirectory), ("Settings", configDirectory)] {
                let existed = fm.fileExists(atPath: dir.path)
                let ok = !existed || (try? fm.removeItem(at: dir)) != nil
                steps.append(Step(name: name, ok: ok, detail: existed ? "deleted \(dir.path)" : "none"))
            }
            steps.append(Step(name: "App preferences", ok: true, detail: run(["/usr/bin/defaults", "delete", bundleID]) ? "deleted" : "none"))
        }
        if let recycleApp { steps.append(Step(name: "App", ok: recycleApp(), detail: "moved to the Trash")) }
        return steps
    }
}
