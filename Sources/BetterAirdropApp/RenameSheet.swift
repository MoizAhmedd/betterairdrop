import AppKit
import BetterAirdropCore
import SwiftUI

/// "Rename Files…", files dropped on the icon, Finder's Services menu and earlier AirDrops all
/// come here: the Planner's dry run as an editable table, then the Committer.
@MainActor
final class RenamePreviewModel: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        var proposal: Proposal
        var name: String
        var original: String { (proposal.source as NSString).lastPathComponent }
        var skipped: Bool { proposal.action == .skip }
    }

    @Published var rows: [Row] = []
    @Published var planning = true
    @Published var committing = false
    let files: [URL]

    init(files: [URL]) { self.files = files }

    var toRename: [Row] { rows.filter { !$0.skipped } }
    var converts: Bool { rows.contains { $0.proposal.action == .convert } }

    /// Proposals with the user's edits applied (the extension is kept, slashes are removed).
    func finalProposals() -> [Proposal] {
        toRename.map { r in
            var p = r.proposal
            guard let target = p.target else { return p }
            let planned = URL(fileURLWithPath: target)
            var name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if name.isEmpty || name.hasPrefix(".") { return p }
            if (name as NSString).pathExtension.lowercased() != planned.pathExtension.lowercased() {
                name += "." + planned.pathExtension
            }
            p.target = planned.deletingLastPathComponent().appendingPathComponent(name).path
            return p
        }
    }
}

struct RenamePreviewView: View {
    @ObservedObject var m: RenamePreviewModel
    let cancel: () -> Void
    let commit: ([Proposal]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if m.planning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working out names for \(m.files.count) file\(m.files.count == 1 ? "" : "s")…").font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text(m.toRename.isEmpty ? "Nothing to rename" : "Rename \(m.toRename.count) photo\(m.toRename.count == 1 ? "" : "s")?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Here are the names BetterAirdrop would use. Click a name to edit it before anything changes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                table.padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                Text(footnote).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(m.committing ? "Renaming…" : "Rename \(m.toRename.count)") {
                    m.committing = true
                    commit(m.finalProposals())
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(m.planning || m.committing || m.toRename.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    var footnote: String {
        m.converts ? "HEIC → JPEG · originals go to the Trash · can be undone" : "Can be undone"
    }

    var table: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Now").frame(width: 170, alignment: .leading)
                Text("Will become")
                Spacer()
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($m.rows) { $row in
                        HStack {
                            Text(row.original).lineLimit(1).truncationMode(.middle).frame(width: 170, alignment: .leading)
                            if row.skipped {
                                Text("left alone: \(row.proposal.reason ?? "skipped")").foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                TextField("", text: $row.name).textFieldStyle(.plain).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: m.rows.count < 10)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
    }
}
