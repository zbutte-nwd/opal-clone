import SwiftUI

@main
@MainActor
struct TetherApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppEnvironment.shared.model
    @State private var router = AppEnvironment.shared.router
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .onOpenURL { router.handle($0) }
                .task { model.start() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.sceneBecameActive()
                    case .background:
                        model.sceneEnteredBackground()
                        AppDelegate.scheduleRefresh()
                    default: break
                    }
                }
        }
    }
}
