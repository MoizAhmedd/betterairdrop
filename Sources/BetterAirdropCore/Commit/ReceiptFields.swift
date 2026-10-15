import Foundation

extension JournalRecord {
    /// What the namer read off a receipt, kept in the journal for "Export Receipts as CSV" (Pro).
    public struct ReceiptFields: Codable, Sendable, Equatable {
        /// The photo's date, `YYYY-MM-DD`.
        public var date: String?
        public var merchant: String?
        public var total: String?
        public init(date: String?, merchant: String?, total: String?) { self.date = date; self.merchant = merchant; self.total = total }
    }
}
