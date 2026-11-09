#if os(iOS) && canImport(ManagedSettings)
import Foundation
import DeviceActivity
import FamilyControls
import ManagedSettings
import TetherCore

/// Registers DeviceActivity schedules so the Monitor extension wakes at the next state
/// transition even when the app is not running (ARCHITECTURE §5).
///
/// Activities:
/// - `tether.t.<epoch>`    one-shot, `[transition, transition + 15 min]`, not repeating. Named by the
///                         transition's Unix time so an unchanged transition keeps its name and is
///                         not stopped/re-registered on every reconcile (W8).
/// - `tether.daily`        repeating 00:00–23:59 (wakes at midnight to re-plan / reset usage)
/// - `tether.usage.<rule>` repeating daily, one `DeviceActivityEvent` named `limit`
///
/// Re-registering an *already running* activity can restart its interval (firing
/// `intervalDidStart` again -> reconcile -> re-register -> loop) and resets usage-event
/// counters, so unchanged activities are left alone; a signature per activity is kept in
/// `activitySignatures.json`. VERIFY: spike S4 (restart semantics, limits).
public final class ActivityScheduler: @unchecked Sendable {
    /// Max simultaneously monitored activities. VERIFY: spike S4 (believed 20).
    public static let maxActivities = 20
    /// Minimum interval length. VERIFY: spike S4 (believed 15 min).
    public static let minIntervalMinutes = 15

    public static let oneShotPrefix = "tether.t."
    public static let dailyName = "tether.daily"
    public static let usagePrefix = "tether.usage."
    public static let usageEventName = "limit"

    public static func usageActivityName(ruleId: RuleID) -> String { usagePrefix + ruleId }
    public static func oneShotActivityName(for date: Date) -> String {
        oneShotPrefix + String(Int(date.timeIntervalSince1970.rounded(.down)))
    }
    /// Inverse of `oneShotActivityName`; nil when `activity` is not a one-shot transition activity.
    public static func transitionDate(fromActivity rawValue: String) -> Date? {
        guard rawValue.hasPrefix(oneShotPrefix), let t = Int(rawValue.dropFirst(oneShotPrefix.count)) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(t))
    }
    /// Inverse of `usageActivityName`; nil when `activity` is not a usage activity.
    public static func ruleId(fromActivity rawValue: String) -> RuleID? {
        rawValue.hasPrefix(usagePrefix) ? String(rawValue.dropFirst(usagePrefix.count)) : nil
    }

    private let center = DeviceActivityCenter()
    private let signaturesURL: URL

    public init(directory: URL? = nil) {
        self.signaturesURL = (directory ?? AppGroup.containerURL).appendingPathComponent("activitySignatures.json")
    }

    // MARK: Public

    /// Brings the registered activities in line with `transitions` and `usageRules`.
    /// Never throws or crashes: failures are logged.
    public func schedule(transitions: [Date],
                         usageRules: [Rule],
                         selections: [GroupID: FamilyActivitySelection],
                         timeZone: TimeZone = .current,
                         now: Date = Date()) {
        // DeviceActivitySchedule interprets DateComponents in the DEVICE calendar/time zone,
        // so absolute instants must be decomposed with the device calendar — not the policy
        // time zone (`timeZone`, which may come from the server bundle). `timeZone` is kept in
        // the signature only so a policy-tz change still forces a re-plan.
        let calendar = Calendar.current

        var sigs = loadSignatures()
        let center = self.center
        // W8-audited (iOS 16+ SDK): `DeviceActivityName(rawValue:)` / `DeviceActivityEvent.Name(rawValue:)`
        // (RawRepresentable<String>), `DeviceActivityCenter.activities: [DeviceActivityName]`,
        // `stopMonitoring(_: [DeviceActivityName] = [])`, `startMonitoring(_:during:events:) throws`.
        let running = Set(center.activities.map { $0.rawValue })
        var desired: [String: (sig: String, register: () throws -> Void)] = [:]

        // 1. daily
        desired[Self.dailyName] = ("daily-v1", {
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true)
            try center.startMonitoring(DeviceActivityName(rawValue: Self.dailyName), during: schedule)
        })

        // 2. usage rules
        var usageCount = 0
        for rule in usageRules {
            guard case .usageLimit(let minutes, _) = rule.trigger, minutes > 0 else { continue }
            var apps = Set<ApplicationToken>(), cats = Set<ActivityCategoryToken>(), webs = Set<WebDomainToken>()
            for gid in rule.groupIds {
                guard let sel = selections[gid] else { continue }
                apps.formUnion(sel.applicationTokens)
                cats.formUnion(sel.categoryTokens)
                webs.formUnion(sel.webDomainTokens)
            }
            guard !(apps.isEmpty && cats.isEmpty && webs.isEmpty) else { continue }
            guard 1 + usageCount + 1 <= Self.maxActivities else {
                TLog.schedule.notice("usage rule \(rule.id) skipped: activity budget exhausted")
                continue
            }
            usageCount += 1
            let name = Self.usageActivityName(ruleId: rule.id)
            let tokenSig = Self.tokenSignature(apps: apps, cats: cats, webs: webs)
            desired[name] = ("usage-v1|\(minutes)|\(tokenSig)", {
                let schedule = DeviceActivitySchedule(
                    intervalStart: DateComponents(hour: 0, minute: 0),
                    intervalEnd: DateComponents(hour: 23, minute: 59),
                    repeats: true)
                // Threshold as hours+minutes so values >= 60 are well-formed.
                let threshold = DateComponents(hour: minutes / 60, minute: minutes % 60)
                let event: DeviceActivityEvent
                if #available(iOS 17.4, *) {
                    // Count usage since the start of today's interval (midnight), not only usage after
                    // registration — a rule added/changed mid-day must still honour "N minutes per day".
                    // Re-firing on re-registration is harmless: recordUsageLimitHit is idempotent per day.
                    // VERIFY: label `includesPastActivity:` (iOS 17.4 SDK).
                    event = DeviceActivityEvent(applications: apps, categories: cats, webDomains: webs,
                                                threshold: threshold, includesPastActivity: true)
                } else {
                    event = DeviceActivityEvent(applications: apps, categories: cats, webDomains: webs,
                                                threshold: threshold)
                }
                try center.startMonitoring(DeviceActivityName(rawValue: name), during: schedule,
                                           events: [DeviceActivityEvent.Name(rawValue: Self.usageEventName): event])
            })
        }

        // 3. one-shot transitions (future only), within the remaining budget
        let budget = max(0, Self.maxActivities - desired.count)
        let future = transitions.filter { $0 > now }.sorted().prefix(budget)
        for transition in future {
            // Round UP to whole seconds: DateComponents carry no sub-second part, and waking a few
            // hundred ms *before* the transition would evaluate the old state (see Monitor).
            let date = Date(timeIntervalSince1970: transition.timeIntervalSince1970.rounded(.up))
            let name = Self.oneShotActivityName(for: date)
            guard desired[name] == nil else { continue }   // two transitions within the same second
            let end = date.addingTimeInterval(TimeInterval(Self.minIntervalMinutes * 60))
            let startComps = Self.components(date, calendar)
            let endComps = Self.components(end, calendar)
            desired[name] = ("t-v2|\(calendar.timeZone.identifier)|\(timeZone.identifier)", {
                let schedule = DeviceActivitySchedule(intervalStart: startComps, intervalEnd: endComps, repeats: false)
                try center.startMonitoring(DeviceActivityName(rawValue: name), during: schedule)
            })
        }

        // 4. stop activities we own that are no longer wanted
        let owned = running.filter { $0 == Self.dailyName || $0.hasPrefix(Self.oneShotPrefix) || $0.hasPrefix(Self.usagePrefix) }
        let stale = owned.subtracting(desired.keys)
        if !stale.isEmpty {
            center.stopMonitoring(stale.map { DeviceActivityName(rawValue: $0) })
            for s in stale { sigs.removeValue(forKey: s) }
        }

        // 5. (re)register changed or missing ones
        for (name, d) in desired.sorted(by: { $0.key < $1.key }) {
            if running.contains(name), sigs[name] == d.sig { continue }
            do {
                if running.contains(name) { center.stopMonitoring([DeviceActivityName(rawValue: name)]) }
                try d.register()
                sigs[name] = d.sig
            } catch {
                sigs.removeValue(forKey: name)
                TLog.schedule.error("startMonitoring(\(name)) failed: \(String(describing: error))")
            }
        }
        saveSignatures(sigs)
    }

    /// Stops every Tether activity (protection disabled).
    public func stopAll() {
        let ours = center.activities.filter {
            $0.rawValue == Self.dailyName || $0.rawValue.hasPrefix(Self.oneShotPrefix) || $0.rawValue.hasPrefix(Self.usagePrefix)
        }
        if !ours.isEmpty { center.stopMonitoring(ours) }
        saveSignatures([:])
    }

    // MARK: Helpers

    static func components(_ date: Date, _ calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private static func tokenSignature(apps: Set<ApplicationToken>, cats: Set<ActivityCategoryToken>,
                                       webs: Set<WebDomainToken>) -> String {
        func keys<T: Encodable>(_ s: Set<T>) -> [String] {
            s.compactMap { try? JSONEncoder().encode($0).base64EncodedString() }.sorted()
        }
        let joined = (keys(apps) + ["|"] + keys(cats) + ["|"] + keys(webs)).joined(separator: ",")
        // Small stable digest (FNV-1a 64) — signatures only need change detection.
        var h: UInt64 = 0xcbf29ce484222325
        for b in joined.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    private func loadSignatures() -> [String: String] {
        guard let d = try? Data(contentsOf: signaturesURL),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    private func saveSignatures(_ m: [String: String]) {
        do { try JSONEncoder().encode(m).write(to: signaturesURL, options: [.atomic]) }
        catch { TLog.schedule.error("signature save failed: \(String(describing: error))") }
    }
}
#endif
