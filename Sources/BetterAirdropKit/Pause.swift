import Foundation

/// "Pause ›" in the menu: For 1 Hour, Until Tomorrow, Until I Resume.
public enum PauseDuration: String, CaseIterable, Sendable {
    case oneHour, untilTomorrow, indefinitely

    public var title: String {
        switch self {
        case .oneHour: "For 1 Hour"
        case .untilTomorrow: "Until Tomorrow"
        case .indefinitely: "Until I Resume"
        }
    }

    /// When watching resumes by itself, or nil for "Until I Resume". "Tomorrow" is 8:00 the next morning.
    public func resumeDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .untilTomorrow:
            let start = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
        case .indefinitely: return nil
        }
    }
}

public enum PauseText {
    /// "Paused until 15:06. AirDrops will be left as they are."
    public static func banner(until: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let until else { return "Paused. AirDrops will be left as they are." }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("jmm")
        let time = f.string(from: until)
        let when = calendar.isDate(until, inSameDayAs: now) ? time : "tomorrow at \(time)"
        return "Paused until \(when). AirDrops will be left as they are."
    }
}
