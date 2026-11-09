import UIKit
import BackgroundTasks
import UserNotifications
import TetherCore
import TetherKit

/// Process-wide singletons shared by the SwiftUI `App` and the `AppDelegate`.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let platform: PlatformServices
    let model: AppModel
    let router = DeepLinkRouter()

    private init() {
        let env = ProcessInfo.processInfo.environment["TETHER_PLATFORM_STUB"]
        var useStub = false
        #if targetEnvironment(simulator)
        useStub = env != "0"      // Simulator defaults to the stub; TETHER_PLATFORM_STUB=0 forces Live.
        #else
        useStub = env == "1"
        #endif
        platform = useStub ? StubPlatformServices() : LivePlatformServices()
        model = AppModel(platform: platform)
    }
}

/// Carries a non-Sendable payload (push userInfo) into a main-actor Task.
struct UncheckedBox<T>: @unchecked Sendable { let value: T }

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskId = "tether.refresh"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationRouter.registerCategories()   // pause category used by the shield-action notification
        // BGTask handlers must be registered before launch finishes.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Self.handleRefresh(task)
        }
        Self.scheduleRefresh()
        application.registerForRemoteNotifications()   // silent pushes need no user permission
        return true
    }

    // MARK: Remote notifications

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await AppEnvironment.shared.model.registerPushToken(hex: hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected in the Simulator / without the aps-environment entitlement.
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let box = UncheckedBox(value: userInfo)
        Task { @MainActor in
            await AppEnvironment.shared.model.handlePush(userInfo: box.value)
            completionHandler(.newData)
        }
    }

    // MARK: Notification center

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // The shield-action extension / NSE put a deep link in userInfo["url"] (e.g. tether://pause?group=…).
        let urlString = response.notification.request.content.userInfo["url"] as? String
        Task { @MainActor in
            if let urlString { AppEnvironment.shared.router.handle(urlString: urlString) }
            completionHandler()
        }
    }

    // MARK: Background refresh

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            await AppEnvironment.shared.model.backgroundRefresh()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
