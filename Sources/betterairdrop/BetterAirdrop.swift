import BetterAirdropCore
import ArgumentParser
import Foundation

@main
struct BetterAirdrop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "betterairdrop",
        abstract: "Name AirDropped photos from their context, on your Mac.",
        version: BetterAirdropVersion.current,
        subcommands: [Rename.self, Explain.self, Watch.self, Undo.self, Log.self, Auth.self]
    )
}

enum BetterAirdropVersion {
    static let current = "0.0.1-dev"
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Config file (default: ~/.config/betterairdrop/config.toml).")
    var config: String?

    func loadConfig() throws -> Config {
        try Config.load(from: config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Config.defaultPath)
    }
}

extension Config.Originals: ExpressibleByArgument {}

/// The planner the CLI uses: local Vision analysis for context, and the configured namer.
func makePlanner(config: Config, backend: String?) throws -> Planner {
    var planner = Planner(config: config)
    do {
        planner.namer = try Backends.resolve(backend ?? config.backend, config: config)
    } catch {
        throw ValidationError("\(error)")
    }
    if let namer = planner.namer, Backends.isCloud(namer) {
        CloudNotice.showOnce { stderr("note: " + $0.replacingOccurrences(of: "\n", with: "\n      ") + "\n") }
    }
    planner.analyzer = { VisionAnalyzer.analyze($0) }
    return planner
}

/// One stderr line per distinct reason a cloud backend fell back to Vision.
func reportFallbacks(_ proposals: [Proposal]) {
    let reasons = proposals.compactMap { $0.suggestion?.fallbackFrom?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
    for (reason, n) in Dictionary(grouping: reasons, by: { $0 }).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
        stderr("note: \(reason); named \(n) file\(n == 1 ? "" : "s") with Apple Vision instead")
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try enc.encode(value), as: UTF8.self))
}

func stderr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// Shortens paths under $HOME to ~/… for display.
func tilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
