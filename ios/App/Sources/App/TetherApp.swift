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
                // `initial: true`: the app usually launches straight into `.active`, which a plain
                // onChange never reports — without it the launch would skip reconcile + sync.
                .onChange(of: scenePhase, initial: true) { _, phase in
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
