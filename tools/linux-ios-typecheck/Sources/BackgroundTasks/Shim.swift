import Foundation
public class BGTask: NSObject {
    public var expirationHandler: (@Sendable () -> Void)?
    public func setTaskCompleted(success: Bool) {}
}
public class BGAppRefreshTask: BGTask {}
public class BGTaskRequest: NSObject { public var earliestBeginDate: Date? }
public class BGAppRefreshTaskRequest: BGTaskRequest { public init(identifier: String) {} }
public class BGTaskScheduler: NSObject, @unchecked Sendable {
    public static let shared = BGTaskScheduler()
    @discardableResult
    public func register(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?,
                         launchHandler: @escaping @Sendable (BGTask) -> Void) -> Bool { true }
    public func submit(_ r: BGTaskRequest) throws {}
}
