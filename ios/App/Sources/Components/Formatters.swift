import Foundation
import TetherCore

enum Fmt {
    static let shortWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    static let fullWeekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    static let initials = ["M", "T", "W", "T", "F", "S", "S"]

    static func weekdayShort(_ iso: ISOWeekday) -> String { (1...7).contains(iso) ? shortWeekdays[iso - 1] : "?" }
    static func weekdayFull(_ iso: ISOWeekday) -> String { (1...7).contains(iso) ? fullWeekdays[iso - 1] : "?" }

    /// "Every day", "Weekdays", "Weekends", or "Mon, Wed".
    static func days(_ days: [ISOWeekday]) -> String {
        let set = Set(days)
        if set.count == 7 { return "Every day" }
        if set == [1, 2, 3, 4, 5] { return "Weekdays" }
        if set == [6, 7] { return "Weekends" }
        if set.isEmpty { return "No days" }
        return set.sorted().map(weekdayShort).joined(separator: ", ")
    }

    // MARK: Minutes-of-day

    /// "HH:mm" -> minutes since midnight (24:00 -> 1440).
    static func minutes(fromHHMM s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...59).contains(m), (0...24).contains(h) else { return nil }
        if h == 24 && m != 0 { return nil }
        return h * 60 + m
    }

    static func hhmm(fromMinutes m: Int) -> String {
        String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// Localised clock text, e.g. "9:00 AM".
    static func clock(minutes m: Int) -> String {
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        let d = cal.date(bySettingHour: (m / 60) % 24, minute: m % 60, second: 0, of: base) ?? base
        return d.formatted(date: .omitted, time: .shortened)
    }

    static func clock(hhmm s: String) -> String {
        guard let m = minutes(fromHHMM: s) else { return s }
        return clock(minutes: m)
    }

    static func window(_ w: Window) -> String {
        let overnight: Bool = {
            guard let a = minutes(fromHHMM: w.start), let b = minutes(fromHHMM: w.end) else { return false }
            return b < a
        }()
        return "\(days(w.days)) \(clock(hhmm: w.start))–\(clock(hhmm: w.end))" + (overnight ? " (next day)" : "")
    }

    // MARK: Durations & dates

    static func duration(minutes m: Int) -> String {
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    static func duration(seconds s: TimeInterval) -> String {
        let t = max(0, Int(s.rounded(.up)))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "3:00 PM" today, "Tomorrow 7:00 AM", or "Wed 7:00 AM".
    static func until(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }
}
