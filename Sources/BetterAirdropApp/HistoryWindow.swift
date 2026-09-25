import AppKit
import BetterAirdropCore
import BetterAirdropKit
import SwiftUI

/// "Show All History…": the journal grouped by batch, newest first, with search and undo.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    let actions: PanelActions
    @State private var batches: [Journal.BatchSummary] = []
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search names", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("\(batches.reduce(0) { $0 + $1.entries.count }) changes").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Show Journal File") { NSWorkspace.shared.activateFileViewerSelecting([model.journal.url]) }
            }
            .padding(10)
            Divider()
            if filtered.isEmpty {
                Text(batches.isEmpty ? "No renames yet." : "Nothing matches “\(query)”.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered, id: \.id) { b in
                        Section {
                            ForEach(b.entries, id: \.begin.source) { e in HistoryRow(entry: e, actions: actions) }
                        } header: {
                            HStack {
                                Text(Self.header(b)).font(.system(size: 11.5, weight: .semibold))
                                Spacer()
                                if !b.undoable.isEmpty {
                                    Button("Undo Batch") { actions.undo(.batch(b.id)) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear(perform: load)
        .onChange(of: model.historyVersion) { _ in load() }
    }

    var filtered: [Journal.BatchSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return batches }
        return batches.compactMap { b in
            var b = b
            b.entries = b.entries.filter { $0.begin.source.lowercased().contains(q) || $0.latest.target.lowercased().contains(q) }
            return b.entries.isEmpty ? nil : b
        }
    }

    func load() {
        let j = model.journal
        DispatchQueue.global(qos: .userInitiated).async {
            let b = j.recentBatches(limit: 1000)
            DispatchQueue.main.async { batches = b }
        }
    }

    static func header(_ b: Journal.BatchSummary) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        var s = "\(f.string(from: b.time)) · \(b.entries.count) file\(b.entries.count == 1 ? "" : "s")"
        if let be = b.backend { s += " · \(be == "claude" ? "Claude" : be == "vision" ? "Apple Vision" : be)" }
        if b.costUSD > 0 { s += String(format: " · $%.4f", b.costUSD) }
        return s
    }
}

struct HistoryRow: View {
    let entry: Journal.Entry
    let actions: PanelActions

    var body: some View {
        let r = entry.latest
        let old = (r.source as NSString).lastPathComponent, new = (r.target as NSString).lastPathComponent
        HStack(spacing: 8) {
            ThumbnailView(path: entry.state == .undo ? r.source : r.target, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(new).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .strikethrough(entry.state == .undo)
                Text("from \(old)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch entry.state {
            case .undo: Text("undone").font(.system(size: 11)).foregroundStyle(.secondary)
            case .error: Text("failed").font(.system(size: 11)).foregroundStyle(.red).help(r.message ?? "")
            case .begin: Text("interrupted").font(.system(size: 11)).foregroundStyle(.orange)
            case .done:
                Button { actions.undo(.file(r.target)) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Undo")
            }
            Button { actions.reveal([entry.state == .undo ? r.source : r.target]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
    }
}
