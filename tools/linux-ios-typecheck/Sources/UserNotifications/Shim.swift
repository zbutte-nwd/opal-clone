import Foundation
public class UNNotificationCategory: NSObject {
    public let identifier: String
    public struct Options: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue } }
    public init(identifier: String, actions: [Any], intentIdentifiers: [String], options: Options = []) { self.identifier = identifier }
}
public enum UNNotificationInterruptionLevel: UInt { case passive, active, timeSensitive, critical }
public class UNNotificationSound: NSObject {}
public class UNNotificationContent: NSObject {
    public internal(set) var userInfo: [AnyHashable: Any] = [:]
}
public class UNMutableNotificationContent: UNNotificationContent {
    public var title = "", body = "", categoryIdentifier = "", threadIdentifier = ""
    public var sound: UNNotificationSound?
    public var interruptionLevel: UNNotificationInterruptionLevel = .active
    public override var userInfo: [AnyHashable: Any] { get { super.userInfo } set { super.userInfo = newValue } }
}
public class UNNotificationTrigger: NSObject {}
public class UNNotificationRequest: NSObject {
    public let content: UNNotificationContent
    public init(identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger?) { self.content = content }
}
public class UNNotification: NSObject { public var request: UNNotificationRequest { fatalError() } }
public class UNNotificationResponse: NSObject { public var notification: UNNotification { fatalError() } }
public struct UNNotificationPresentationOptions: OptionSet {
    public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let banner = Self(rawValue: 1), list = Self(rawValue: 2), sound = Self(rawValue: 4), badge = Self(rawValue: 8)
}
public struct UNAuthorizationOptions: OptionSet {
    public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let alert = Self(rawValue: 1), sound = Self(rawValue: 2), badge = Self(rawValue: 4)
}
public protocol UNUserNotificationCenterDelegate: NSObjectProtocol {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void)
}
public class UNUserNotificationCenter: NSObject, @unchecked Sendable {
    public class func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
    public weak var delegate: UNUserNotificationCenterDelegate?
    public func getNotificationCategories(completionHandler: @escaping @Sendable (Set<UNNotificationCategory>) -> Void) {}
    public func setNotificationCategories(_ c: Set<UNNotificationCategory>) {}
    public func add(_ request: UNNotificationRequest, withCompletionHandler: (@Sendable (Error?) -> Void)? = nil) {}
    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
}
open class UNNotificationServiceExtension: NSObject {
    public override init() {}
    open func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {}
    open func serviceExtensionTimeWillExpire() {}
}
