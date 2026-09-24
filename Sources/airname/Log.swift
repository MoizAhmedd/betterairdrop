import AirnameCore
import ArgumentParser
import Foundation

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recent renames (old → new).")

    @Option(name: .short, help: "How many entries to show.")
    var n = 20

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func run() throws {
        let journal = Journal()
        let entries = Array(journal.entries().suffix(n))
        if json { try printJSON(entries.map(\.latest)); return }
        if entries.isEmpty { print("No renames yet. (\(tilde(journal.url.path)))"); return }
        var lastBatch = ""
        for e in entries {
            let r = e.latest
            if r.batch != lastBatch {
                print("batch \(r.batch)  \(r.time.prefix(19).replacingOccurrences(of: "T", with: " "))")
                lastBatch = r.batch
            }
            let state: String = switch r.op {
            case .done: ""
            case .undo: "  [undone]"
            case .error: "  [failed: \(r.message ?? "")]"
            case .begin: "  [interrupted; `airname undo` will clean up]"
            }
            let backend = r.backend.map { "  (\($0))" } ?? ""
            print("  \((r.source as NSString).lastPathComponent)  →  \((r.target as NSString).lastPathComponent)\(backend)\(state)")
        }
    }
}
