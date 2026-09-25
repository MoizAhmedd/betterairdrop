import Foundation

/// The "2 min ago" / "Yesterday" / "Mon" text in the menu's Recent rows.
public enum RelativeTime {
    public static func string(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(s / 3600)) h ago" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(s < 6 * 86400 ? "EEE" : "MMMd")
        return f.string(from: date)
    }
}
