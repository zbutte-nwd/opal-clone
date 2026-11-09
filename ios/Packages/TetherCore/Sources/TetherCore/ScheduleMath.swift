// ScheduleMath.swift — wall-clock schedule helpers shared by PolicyEngine and TransitionPlanner.
//
// All calendar arithmetic uses a Gregorian `Calendar` pinned to the *effective* time zone.
// Windows are defined in local wall-clock time, so DST is handled by wall clock:
//  - activity checks compare the local "minute of day" (a spring-forward gap simply skips
//    the missing hour; a fall-back repeats it),
//  - boundary enumeration maps "HH:mm" on a given local day to a concrete `Date`; a
//    nonexistent local time (spring-forward gap) rounds forward to the instant the gap ends.

import Foundation

public enum ScheduleMath {

    // MARK: Calendar

    /// Gregorian calendar pinned to `timeZone` (POSIX locale so numerals are stable).
    public static func calendar(_ timeZone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// A date broken down in a time zone — computed once per evaluation and reused.
    public struct LocalMoment: Sendable, Hashable {
        /// 1 = Monday … 7 = Sunday.
        public var isoWeekday: ISOWeekday
        /// Minutes since local midnight, including seconds as a fraction (0 ..< 1440).
        public var minuteOfDay: Double
        /// "YYYY-MM-DD" in the zone.
        public var day: String
    }

    public static func localMoment(_ date: Date, in timeZone: TimeZone) -> LocalMoment {
        localMoment(date, calendar: calendar(timeZone))
    }

    static func localMoment(_ date: Date, calendar cal: Calendar) -> LocalMoment {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        return LocalMoment(
            isoWeekday: isoWeekday(fromGregorian: c.weekday ?? 1),
            minuteOfDay: Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60.0,
            day: dayString(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1))
    }

    /// Gregorian weekday (1 = Sunday … 7 = Saturday) → ISO (1 = Monday … 7 = Sunday).
    static func isoWeekday(fromGregorian w: Int) -> ISOWeekday { (w + 5) % 7 + 1 }

    /// ISO weekday of `date` in `timeZone` (1 = Mon … 7 = Sun).
    public static func isoWeekday(of date: Date, in timeZone: TimeZone) -> ISOWeekday {
        isoWeekday(fromGregorian: calendar(timeZone).component(.weekday, from: date))
    }

    /// Local day string "YYYY-MM-DD".
    public static func dayString(_ date: Date, in timeZone: TimeZone) -> String {
        localMoment(date, in: timeZone).day
    }

    static func dayString(year: Int, month: Int, day: Int) -> String {
        func pad(_ n: Int, _ w: Int) -> String {
            let s = String(n)
            return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
        }
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
    }

    public static func startOfDay(_ date: Date, in timeZone: TimeZone) -> Date {
        calendar(timeZone).startOfDay(for: date)
    }

    /// First local midnight strictly after `date`.
    public static func nextMidnight(after date: Date, in timeZone: TimeZone) -> Date {
        let cal = calendar(timeZone)
        let start = cal.startOfDay(for: date)
        let next = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return cal.startOfDay(for: next)
    }

    // MARK: "HH:mm" parsing

    /// Parses "HH:mm" (also "24:00") into minutes since midnight (0 ... 1440). nil if malformed.
    public static func parseMinutes(_ s: String) -> Int? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count >= 1, parts[0].count <= 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              (0...24).contains(h), (0...59).contains(m) else { return nil }
        if h == 24 && m != 0 { return nil }
        return h * 60 + m
    }

    // MARK: Window activity

    /// Is `window` active at the given local moment? Half-open `[start, end)`; `days` are the days
    /// on which the window STARTS; `end < start` runs overnight into the next day; `start == end`
    /// or malformed times are never active.
    public static func isActive(_ window: Window, at m: LocalMoment) -> Bool {
        guard let s = parseMinutes(window.start), let e = parseMinutes(window.end), s != e, s < 1440 else { return false }
        let mins = m.minuteOfDay
        let sD = Double(s), eD = Double(e)
        if e > s {
            return window.days.contains(m.isoWeekday) && sD <= mins && mins < eD
        }
        // Overnight: starts on a listed day at `start`, or is the tail of one that started yesterday.
        let prev = m.isoWeekday == 1 ? 7 : m.isoWeekday - 1
        return (window.days.contains(m.isoWeekday) && mins >= sD) || (window.days.contains(prev) && mins < eD)
    }

    public static func isActive(_ window: Window, at date: Date, in timeZone: TimeZone) -> Bool {
        isActive(window, at: localMoment(date, in: timeZone))
    }

    public static func isAnyActive(_ windows: [Window], at m: LocalMoment) -> Bool {
        windows.contains { isActive($0, at: m) }
    }

    // MARK: Boundary enumeration

    /// The concrete instant of `minutes` (0 ... 1440) after local midnight on the local day that
    /// begins at `dayStart`. Nonexistent wall-clock times (DST gap) round forward to the end of
    /// the gap; ambiguous times (DST overlap) resolve to the first occurrence.
    public static func instant(onDayStarting dayStart: Date, minutes: Int, calendar cal: Calendar) -> Date {
        if minutes <= 0 { return dayStart }
        let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let nextStart = cal.startOfDay(for: nextDay)
        if minutes >= 1440 { return nextStart }

        let base = dayStart.addingTimeInterval(Double(minutes) * 60)
        let target = cal.dateComponents([.year, .month, .day], from: dayStart)
        var firstAfter: Date?
        for off in [-3600.0, -1800.0, 0, 1800.0, 3600.0] {
            let c = base.addingTimeInterval(off)
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: c)
            guard comps.year == target.year, comps.month == target.month, comps.day == target.day else { continue }
            let wall = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            if wall == minutes && (comps.second ?? 0) == 0 { return c }
            if wall > minutes && firstAfter == nil { firstAfter = c }
        }
        // Nonexistent local time: the DST transition instant is where the gap ends.
        if let after = firstAfter {
            if let t = cal.timeZone.nextDaylightSavingTimeTransition(after: base.addingTimeInterval(-7200)), t <= after {
                return t
            }
            return after
        }
        return base
    }

    /// Concrete `[start, end)` occurrences of `window` that intersect `[from, to]`.
    public static func occurrences(of window: Window, from: Date, to: Date, in timeZone: TimeZone) -> [DateInterval] {
        occurrences(of: window, from: from, to: to, calendar: calendar(timeZone))
    }

    static func occurrences(of window: Window, from: Date, to: Date, calendar cal: Calendar) -> [DateInterval] {
        guard let s = parseMinutes(window.start), let e = parseMinutes(window.end), s != e, s < 1440, to >= from
        else { return [] }
        var out: [DateInterval] = []
        // Start one day early so an overnight window that began yesterday is included.
        var day = cal.startOfDay(for: from.addingTimeInterval(-86400))
        let last = cal.startOfDay(for: to)
        while day <= last {
            let iso = isoWeekday(fromGregorian: cal.component(.weekday, from: day))
            if window.days.contains(iso) {
                let start = instant(onDayStarting: day, minutes: s, calendar: cal)
                let endDay = e > s ? day : (cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400))
                let end = instant(onDayStarting: cal.startOfDay(for: endDay), minutes: e, calendar: cal)
                if end > start, end > from, start <= to { out.append(DateInterval(start: start, end: end)) }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            let ns = cal.startOfDay(for: next)
            if ns <= day { break }
            day = ns
        }
        return out
    }

    /// All start and end instants of `windows` that lie in `(from, to]`, sorted and de-duplicated.
    public static func boundaries(of windows: [Window], after from: Date, through to: Date, in timeZone: TimeZone) -> [Date] {
        let cal = calendar(timeZone)
        var set = Set<Date>()
        for w in windows {
            for iv in occurrences(of: w, from: from, to: to, calendar: cal) {
                if iv.start > from && iv.start <= to { set.insert(iv.start) }
                if iv.end > from && iv.end <= to { set.insert(iv.end) }
            }
        }
        return set.sorted()
    }

    /// Local midnights in `(from, to]`.
    public static func midnights(after from: Date, through to: Date, in timeZone: TimeZone) -> [Date] {
        var out: [Date] = []
        var t = nextMidnight(after: from, in: timeZone)
        while t <= to {
            out.append(t)
            let n = nextMidnight(after: t, in: timeZone)
            if n <= t { break }
            t = n
        }
        return out
    }
}
