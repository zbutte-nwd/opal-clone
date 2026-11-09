import Foundation
import ManagedSettings
public struct DeviceActivityName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
public struct DeviceActivityEvent {
    public struct Name: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }
    public init(applications: Set<ApplicationToken> = [], categories: Set<ActivityCategoryToken> = [],
                webDomains: Set<WebDomainToken> = [], threshold: DateComponents) {}
    public init(applications: Set<ApplicationToken> = [], categories: Set<ActivityCategoryToken> = [],
                webDomains: Set<WebDomainToken> = [], threshold: DateComponents, includesPastActivity: Bool) {}
}
public struct DeviceActivitySchedule {
    public init(intervalStart: DateComponents, intervalEnd: DateComponents, repeats: Bool, warningTime: DateComponents? = nil) {}
}
public class DeviceActivityCenter {
    public init() {}
    public var activities: [DeviceActivityName] { [] }
    public func startMonitoring(_ activity: DeviceActivityName, during schedule: DeviceActivitySchedule,
                                events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]) throws {}
    public func stopMonitoring(_ activities: [DeviceActivityName] = []) {}
}
open class DeviceActivityMonitor: NSObject {
    public override init() {}
    open func intervalDidStart(for activity: DeviceActivityName) {}
    open func intervalDidEnd(for activity: DeviceActivityName) {}
    open func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {}
    open func intervalWillStartWarning(for activity: DeviceActivityName) {}
    open func intervalWillEndWarning(for activity: DeviceActivityName) {}
    open func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {}
}
