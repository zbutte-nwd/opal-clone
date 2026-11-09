// ShieldCopy.swift — pure text for the shield screen (ShieldConfiguration extension).
//
//   title    "Social is blocked"
//   subtitle "School hours · until 3:00 PM" | "Focus session · 12 min left" | "Blocked by your admin"
//   button   "Unlock for 5 min" — only when the block is not strict
//
// Names are looked up in the EngineInput; time formatting is injectable so tests are deterministic.

import Foundation

public struct ShieldCopy: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var showsUnlockButton: Bool
    public var unlockButtonTitle: String

    /// Formats instants for display. `time` -> "3:00 PM"; `weekdayTime` -> "Tue 8:00 AM" (used when the
    /// instant is not on the same local day as `now`).
    public struct Formatter: Sendable {
        public var time: @Sendable (Date) -> String
        public var weekdayTime: @Sendable (Date) -> String
        public init(time: @escaping @Sendable (Date) -> String, weekdayTime: @escaping @Sendable (Date) -> String) {
            self.time = time; self.weekdayTime = weekdayTime
        }

        public static func standard(locale: Locale = .current, timeZone: TimeZone) -> Formatter {
            // DateFormatter is not Sendable; create one per call (cheap, shield rendering is rare).
            Formatter(
                time: { date in
                    let f = DateFormatter(); f.locale = locale; f.timeZone = timeZone
                    f.dateStyle = .none; f.timeStyle = .short
                    return f.string(from: date)
                },
                weekdayTime: { date in
                    let f = DateFormatter(); f.locale = locale; f.timeZone = timeZone
                    f.setLocalizedDateFormatFromTemplate("EEE jmm")
                    return f.string(from: date)
                })
        }
    }

    public static func minutesLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    public static func make(groupId: GroupID, state: GroupState, input: EngineInput, now: Date,
                            timeZone: TimeZone, formatter: Formatter? = nil, unlockMinutes: Int = 5) -> ShieldCopy {
        let fmt = formatter ?? .standard(timeZone: timeZone)
        let name = input.allGroups.first { $0.id == groupId }?.name ?? "This app"
        return make(groupName: name, state: state, input: input, now: now, timeZone: timeZone,
                    formatter: fmt, unlockMinutes: unlockMinutes)
    }

    public static func make(groupName: String, state: GroupState, input: EngineInput, now: Date,
                            timeZone: TimeZone, formatter: Formatter, unlockMinutes: Int = 5) -> ShieldCopy {
        let title = state.blocked ? "\(groupName) is blocked" : "\(groupName) is unblocked"
        let button = "Unlock for \(unlockMinutes) min"
        let showButton = state.blocked && !state.strict

        func untilText() -> String? {
            guard let until = state.until else { return nil }
            let sameDay = ScheduleMath.dayString(until, in: timeZone) == ScheduleMath.dayString(now, in: timeZone)
            return "until " + (sameDay ? formatter.time(until) : formatter.weekdayTime(until))
        }
        func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }

        var subtitle = ""
        if state.blocked {
            switch state.reason.kind {
            case .override:
                subtitle = join(["Blocked by your admin", untilText()])
            case .session:
                let s = input.sessions.first { $0.id == state.reason.id }
                let left: String? = s.map { sess in
                    let end = min(sess.endsAt, sess.endedAt ?? sess.endsAt)
                    let mins = max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
                    return "\(minutesLabel(mins)) left"
                }
                subtitle = join([s?.name ?? "Focus session", left])
            case .rule:
                let rule = PolicyEngine.effectiveRules(input).first { $0.id == state.reason.id }
                subtitle = join([rule?.name ?? "Scheduled block", untilText()])
            case .pause, .none:
                subtitle = untilText().map { "Blocked · \($0)" } ?? "Blocked"
            }
        }
        return ShieldCopy(title: title, subtitle: subtitle, showsUnlockButton: showButton, unlockButtonTitle: button)
    }
}
