import Foundation

/// How the `{date}` token is written (`date_format` in the config). The capture date is always
/// read as `YYYY-MM-DD`; this only changes how it appears in the name.
public enum DateFormat: String, Sendable, CaseIterable {
    case iso = "yyyy-mm-dd"
    case compact = "yyyymmdd"
    case month = "yyyy-mm"
    case dayFirst = "dd-mm-yyyy"
    case monthFirst = "mm-dd-yyyy"

    /// `2026-09-24` in this format. Anything that isn't a `YYYY-MM-DD` date is returned as it is.
    public func apply(_ iso: String) -> String {
        let p = iso.split(separator: "-").map(String.init)
        guard self != .iso, p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2 else { return iso }
        let (y, m, d) = (p[0], p[1], p[2])
        switch self {
        case .iso: return iso
        case .compact: return y + m + d
        case .month: return "\(y)-\(m)"
        case .dayFirst: return "\(d)-\(m)-\(y)"
        case .monthFirst: return "\(m)-\(d)-\(y)"
        }
    }
}
