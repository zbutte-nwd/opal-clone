@_exported import Foundation
import Foundation
public class UIColor {
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {}
    public class var label: UIColor { UIColor(red: 0, green: 0, blue: 0, alpha: 1) }
    public class var secondaryLabel: UIColor { label }
    public class var systemBackground: UIColor { label }
    public class var white: UIColor { label }
    public func withAlphaComponent(_ a: CGFloat) -> UIColor { self }
}
public class UIImage { public init?(systemName: String) {} }
public class UIBlurEffect { public enum Style: Int { case systemUltraThinMaterial, systemMaterial, regular } }
@MainActor public class UIDevice {
    public static var current: UIDevice { UIDevice() }
    public var name: String { "" }; public var model: String { "" }; public var systemVersion: String { "" }
}
public enum UIBackgroundFetchResult: UInt { case newData, noData, failed }
@MainActor open class UIApplication {
    public struct LaunchOptionsKey: Hashable, RawRepresentable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
    public static var shared: UIApplication { UIApplication() }
    public static let openSettingsURLString = "app-settings:"
    public func registerForRemoteNotifications() {}
    public func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) {}
}
@MainActor public protocol UIApplicationDelegate: NSObjectProtocol {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data)
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error)
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void)
}
