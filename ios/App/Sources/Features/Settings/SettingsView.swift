import SwiftUI
import TetherCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    NavigationLink { PairingView() } label: {
                        row("antenna.radiowaves.left.and.right", "Remote control",
                            model.isPaired ? "Paired" : "Not paired")
                    }
                }
                Section("Protection") {
                    NavigationLink { ProtectionView() } label: {
                        row("lock.shield", "Protection Lock", model.state.protection.enabled ? lockName : "Off")
                    }
                    NavigationLink { HardeningScreen() } label: {
                        row("checklist", "Screen Time hardening",
                            "\(model.hardeningChecks.intersection(HardeningChecklistView.items.map(\.key)).count) of \(HardeningChecklistView.items.count) done")
                    }
                    if model.screenTimeAuth != .approved {
                        HStack {
                            Label("Screen Time access", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Spacer()
                            Button("Allow") { Task { _ = await model.requestAuthorization(mode: model.state.protection.authMode) } }
                        }
                    }
                }
                Section("About") {
                    NavigationLink { DiagnosticsView() } label: { row("stethoscope", "About & diagnostics", versionString) }
                }
                Section {
                    Text("Tether never uses Face ID or Touch ID. iOS only lets the Screen Time passcode protect Tether at the system level.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var lockName: String {
        switch model.protectionLock {
        case .partnerPIN: return "Partner PIN"
        case .remoteApproval: return "Remote approval"
        case .osOnly: return "iOS only"
        }
    }
    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "v\(v)"
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 28).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary).font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HardeningScreen: View {
    var body: some View {
        ScrollView { HardeningChecklistView().padding() }
            .navigationTitle("Screen Time hardening").navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Settings") { SettingsView().environment(AppModel.preview()) }
