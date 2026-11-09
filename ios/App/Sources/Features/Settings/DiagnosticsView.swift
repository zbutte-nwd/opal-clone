import SwiftUI
import UIKit
import TetherCore

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var showState = false

    var body: some View {
        List {
            Section("App") {
                LabeledContent("Version", value: version)
                LabeledContent("Platform", value: model.platform.isStub ? "Stub (Simulator)" : "Live")
                LabeledContent("Time zone", value: model.timeZone.identifier)
            }
            Section("State") {
                LabeledContent("Pending events", value: "\(model.state.pendingEvents.count)")
                LabeledContent("Policy version", value: model.state.bundle.map { "\($0.version)" } ?? "—")
                LabeledContent("Applied version", value: model.state.appliedBundleVersion.map(String.init) ?? "—")
                LabeledContent("Last reconcile", value: model.state.lastReconciledAt.map { Fmt.relative($0) } ?? "never")
                LabeledContent("Last sync", value: model.state.lastSyncAt.map { Fmt.relative($0) } ?? "never")
            }
            Section {
                Button("Force reconcile") { model.forceReconcile() }
                Button("Sync now") { Task { await model.syncNow() } }
                Button("View state.json") { showState = true }
                Button("Re-run onboarding", role: .destructive) { model.resetOnboardingForDebug() }
            }
            Section {
                Text("Tether stores no analytics. Face ID and Touch ID are never used.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showState) {
            NavigationStack {
                ScrollView {
                    Text(model.prettyStateJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("state.json").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { showState = false } }
                    ToolbarItem(placement: .primaryAction) { Button("Copy") { UIPasteboard.general.string = model.prettyStateJSON } }
                }
            }
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }
}

#Preview("Diagnostics") { NavigationStack { DiagnosticsView() }.environment(AppModel.preview()) }
