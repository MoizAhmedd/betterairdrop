import BetterAirdropCore
import ArgumentParser
import Foundation

struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Name (and convert) specific files.",
        discussion: "Nothing changes on disk with --dry-run. Without it, HEIC files are converted to JPEG and the original goes to the Trash (see `betterairdrop undo`)."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Image files to rename.", completion: .file())
    var files: [String]

    @Flag(help: "Show what would happen without changing anything.")
    var dryRun = false

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    @Option(help: "Naming backend: auto, claude, vision, apple (macOS 27).")
    var backend: String?

    @Option(help: "Filename template, e.g. \"{date}_{place}_{subject}\".")
    var template: String?

    @Flag(help: "Only touch files AirDrop delivered (quarantine agent sharingd).")
    var airdropOnly = false

    @Option(help: "What to do with a converted HEIC's original: trash, keep or delete.")
    var originals: Config.Originals?

    @Option(help: "Output format for HEIC: jpeg (convert) or keep (rename only).")
    var format: OutputFormat?

    enum OutputFormat: String, ExpressibleByArgument { case jpeg, keep }

    mutating func run() throws {
        var config = try global.loadConfig()
        if let originals { config.originals = originals }
        if let format { config.convertHEIC = format == .jpeg }
        if let template { _ = try Template(template) }
        var planner = try makePlanner(config: config, backend: backend)
        planner.templateOverride = template
        planner.airdropOnly = airdropOnly
        let urls = files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let proposals = planner.plan(urls)
        reportFallbacks(proposals)

        if dryRun {
            if json { try printJSON(proposals) } else { printPlan(proposals) }
            return
        }

        for dir in Set(proposals.map { URL(fileURLWithPath: $0.source).deletingLastPathComponent() }) {
            Committer.sweepTemporaries(in: dir)
        }
        let batch = Journal.newBatchID()
        let committer = Committer(config: config)
        committer.backend = planner.namer?.id ?? "none"
        let outcomes = try committer.commit(proposals, batch: batch)
        if json {
            try printJSON(CommitReport(batch: batch, results: outcomes))
        } else {
            printOutcomes(outcomes, batch: batch)
        }
        if outcomes.contains(where: { $0.status == .failed }) { throw ExitCode(1) }
    }

    struct CommitReport: Encodable {
        var batch: String
        var results: [Committer.Outcome]
    }

    func printOutcomes(_ outcomes: [Committer.Outcome], batch: String) {
        for o in outcomes {
            let src = (o.source as NSString).lastPathComponent
            switch o.status {
            case .done: print("  ✓ \(src)  →  \(((o.target ?? "") as NSString).lastPathComponent)\(o.trashed != nil ? "  (original in Trash)" : "")")
            case .skipped: print("  – \(src)  (\(o.message ?? "skipped"))")
            case .failed: print("  ✗ \(src)  \(o.message ?? "")")
            }
        }
        let n = outcomes.filter { $0.status == .done }.count
        if n > 0 { print("Renamed \(n) file\(n == 1 ? "" : "s"). Undo with: betterairdrop undo --batch \(batch)") }
    }

    func printPlan(_ proposals: [Proposal]) {
        for p in proposals {
            let src = (p.source as NSString).lastPathComponent
            switch p.action {
            case .skip: print("  skip     \(src)  (\(p.reason ?? ""))")
            case .convert, .rename:
                let verb = p.action == .convert ? "convert" : "rename "
                print("  \(verb)  \(src)  →  \(((p.target ?? "") as NSString).lastPathComponent)")
            }
        }
    }
}
