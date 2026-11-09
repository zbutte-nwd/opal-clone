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
/// - `tether.t.<n>`        one-shot, `[transition, transition + 15 min]`, not repeating
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var sigs = loadSignatures()
        let center = self.center
        // VERIFY: `DeviceActivityName(rawValue:)` / `DeviceActivityEvent.Name(rawValue:)` exist (both are RawRepresentable<String>);
        // VERIFY: `DeviceActivityCenter.activities` and `stopMonitoring(_: [DeviceActivityName])` signatures.
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
                // VERIFY: DeviceActivityEvent.init(applications:categories:webDomains:threshold:)
                let event = DeviceActivityEvent(applications: apps, categories: cats, webDomains: webs,
                                                threshold: DateComponents(hour: minutes / 60, minute: minutes % 60))
                try center.startMonitoring(DeviceActivityName(rawValue: name), during: schedule,
                                           events: [DeviceActivityEvent.Name(rawValue: Self.usageEventName): event])
            })
        }

        // 3. one-shot transitions (future only), within the remaining budget
        let budget = max(0, Self.maxActivities - desired.count)
        let future = transitions.filter { $0 > now }.sorted().prefix(budget)
        for (i, date) in future.enumerated() {
            let name = "\(Self.oneShotPrefix)\(i)"
            let end = date.addingTimeInterval(TimeInterval(Self.minIntervalMinutes * 60))
            let startComps = Self.components(date, calendar)
            let endComps = Self.components(end, calendar)
            desired[name] = ("t|\(Int(date.timeIntervalSince1970))|\(timeZone.identifier)", {
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
