import BetterAirdropCore
import Foundation

/// "Export Receipts as CSV…" (Pro): every receipt BetterAirdrop renamed and that hasn't been
/// undone, from the journal: date, merchant, total, and where the file is now.
public enum ReceiptsCSV {
    public static let header = "date,merchant,total,file"

    public struct Row: Equatable, Sendable {
        public var date: String
        public var merchant: String
        public var total: String
        public var file: String
    }

    /// Oldest first. Receipts renamed before this field existed are included with what's known
    /// (the day they were renamed, no merchant or total).
    public static func rows(_ entries: [Journal.Entry]) -> [Row] {
        entries.compactMap { e -> Row? in
            guard e.state == .done else { return nil }
            let r = e.begin.receipt
            guard r != nil || e.begin.summary?.hasPrefix("receipt") == true else { return nil }
            guard (e.begin.source as NSString).pathExtension.lowercased() != "mov" else { return nil }
            let renamed = String(e.begin.time.prefix(10))
            return Row(date: r?.date ?? renamed, merchant: r?.merchant ?? "", total: r?.total ?? "", file: e.latest.target)
        }
        .enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
    }

    public static func make(_ entries: [Journal.Entry]) -> String {
        ([header] + rows(entries).map { [$0.date, $0.merchant, $0.total, $0.file].map(cell).joined(separator: ",") })
            .joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting, and a leading `'` on text a spreadsheet would run as a formula
    /// (`=`, `+`, `@`, or `-` not followed by a number).
    static func cell(_ s: String) -> String {
        var v = s
        if let first = v.first {
            let numeric = v.dropFirst().first.map { $0.isNumber || $0 == "." } ?? false
            if "=+@\t\r".contains(first) || (first == "-" && !numeric) { v = "'" + v }
        }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
