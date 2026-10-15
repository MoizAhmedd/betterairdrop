import BetterAirdropCore
import BetterAirdropKit
import ArgumentParser
import Foundation

@main
struct BetterAirdrop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "betterairdrop",
        abstract: "Name AirDropped photos from their context, on your Mac.",
        version: BetterAirdropVersion.current,
        subcommands: [Rename.self, Explain.self, Watch.self, Undo.self, Log.self, Status.self, Setup.self, Auth.self, LicenseCommand.self, Uninstall.self]
    )
}

enum BetterAirdropVersion {
    static let current = "0.4.1"
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Config file (default: ~/.config/betterairdrop/config.toml).")
    var config: String?

    func loadConfig() throws -> Config {
        try Config.load(from: config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Config.defaultPath)
    }
}

extension Config.Originals: ExpressibleByArgument {}

/// Pro with "Name PDFs too" on (`name_pdfs`, on by default): the same rule as the app.
func namesPDFs(_ config: Config) -> Bool { config.namePDFs && LicenseStore().licenseKey() != nil }

/// The planner the CLI uses: local Vision analysis for context, and the configured namer. With
/// Pro and `name_pdfs`, PDFs too, with their own text-only engine.
func makePlanner(config: Config, backend: String?) throws -> Planner {
    var planner = Planner(config: config)
    if namesPDFs(config) {
        planner.pdfs = true
        planner.documentNamer = Backends.resolveDocuments(backend ?? config.backend, config: config, license: LicenseStore())
        if let d = planner.documentNamer, Backends.isCloud(d) {
            CloudNotice.showPDFNoteOnce { stderr("note: " + $0.replacingOccurrences(of: "\n", with: "\n      ") + "\n") }
        }
    }
    do {
        planner.namer = try Backends.resolve(backend ?? config.backend, config: config, license: LicenseStore(), trial: TrialStore())
    } catch {
        throw ValidationError("\(error)")
    }
    if let namer = planner.namer, Backends.isCloud(namer) {
        CloudNotice.showOnce { stderr("note: " + $0.replacingOccurrences(of: "\n", with: "\n      ") + "\n") }
    }
    planner.analyzer = { VisionAnalyzer.analyze($0) }
    return planner
}

/// One stderr line per distinct reason and fallback engine (hosted naming may fall back to Apple Intelligence).
func reportFallbacks(_ proposals: [Proposal]) {
    struct Key: Hashable, Comparable {
        var reason: String, engine: String
        static func < (a: Key, b: Key) -> Bool { (a.reason, a.engine) < (b.reason, b.engine) }
    }
    let keys = proposals.compactMap { p -> Key? in
        guard let s = p.suggestion, let why = s.fallbackFrom?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) else { return nil }
        return Key(reason: why, engine: s.backend == "apple" ? "Apple Intelligence" : "Apple Vision")
    }
    for (k, n) in Dictionary(grouping: keys, by: { $0 }).mapValues(\.count).sorted(by: { $0.key < $1.key }) {
        stderr("note: \(k.reason); named \(n) file\(n == 1 ? "" : "s") with \(k.engine) instead")
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
func tilde(_ path: String) -> String { StatusReport.tilde(path) }
