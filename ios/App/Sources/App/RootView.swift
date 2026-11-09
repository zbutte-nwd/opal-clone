import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeepLinkRouter.self) private var router

    var body: some View {
        Group {
            if model.hasOnboarded {
                MainTabView()
            } else {
                OnboardingFlow()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.lastError ?? "") }
        .onChange(of: router.route) { _, new in
            // Hold links until onboarding is done.
            if !model.hasOnboarded, let new { router.pending = new; router.route = nil }
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(DeepLinkRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }
            GroupsView().tabItem { Label("Groups", systemImage: "square.grid.2x2.fill") }
            RulesView().tabItem { Label("Schedules", systemImage: "calendar.badge.clock") }
            InsightsView().tabItem { Label("Insights", systemImage: "chart.bar.fill") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .sheet(item: $router.route) { route in
            switch route {
            case .pair(let code, let server):
                NavigationStack { PairingView(prefillCode: code, prefillServer: server) }
            case .pause(let gid):
                NavigationStack { PauseFlowView(groupId: gid) }
            case .newSession:
                NavigationStack { StartSessionView() }
            }
        }
        .onAppear { router.releasePending() }
    }
}
