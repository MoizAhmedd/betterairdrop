import AirnameCore
import ArgumentParser
import Foundation

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Put files back exactly as they were, from the journal.",
        discussion: "With no arguments, undoes the last batch. Originals come back from the Trash; converted JPEGs are removed. Refuses to touch an output you've edited since, unless --force."
    )

    @Flag(help: "Undo the most recent batch (the default).")
    var last = false

    @Option(help: "Undo a specific batch (IDs are shown by `airname log`).")
    var batch: String?

    @Argument(help: "Undo the change that produced (or consumed) this file.", completion: .file())
    var file: String?

    @Flag(help: "Undo even if the output was modified since airname wrote it.")
    var force = false

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func validate() throws {
        if [last, batch != nil, file != nil].filter({ $0 }).count > 1 {
            throw ValidationError("Pass only one of --last, --batch or a file.")
        }
    }

    func run() throws {
        let selection: Undoer.Selection = batch.map { .batch($0) }
            ?? file.map { .file(($0 as NSString).expandingTildeInPath) } ?? .last
        var undoer = Undoer()
        undoer.force = force
        let outcomes: [Undoer.Outcome]
        do { outcomes = try undoer.undo(selection) } catch let e as Undoer.Error {
            stderr("airname: \(e)")
            throw ExitCode(1)
        }
        if json { try printJSON(outcomes); return }
        for o in outcomes {
            let t = (o.target as NSString).lastPathComponent, s = (o.source as NSString).lastPathComponent
            switch o.status {
            case .restored: print("  ✓ \(t)  →  \(s)")
            case .alreadyClean: print("  – \(s)  (\(o.message ?? "nothing to do"))")
            case .refused: print("  ! \(t)  \(o.message ?? "")")
            case .failed: print("  ✗ \(t)  \(o.message ?? "")")
            }
        }
        if outcomes.contains(where: { $0.status == .failed || $0.status == .refused }) { throw ExitCode(1) }
    }
}
