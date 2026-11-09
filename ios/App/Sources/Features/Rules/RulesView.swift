import SwiftUI
import TetherCore

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var showNew = false

    private var local: [Rule] { model.state.localRules }
    private var server: [Rule] { model.state.bundle?.rules ?? [] }

    var body: some View {
        NavigationStack {
            Group {
                if local.isEmpty && server.isEmpty {
                    EmptyState(icon: "calendar.badge.clock", title: "No schedules yet",
                               message: "Block groups at set times or after a daily usage limit.",
                               actionTitle: "Add a schedule") { showNew = true }
                } else {
                    List {
                        if !model.allowLocalRules {
                            StatusBanner(style: .info, title: "Local schedules are turned off",
                                         message: "Your admin manages all schedules on this device.")
                                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                        }
                        if !local.isEmpty {
                            Section("On this device") {
                                ForEach(local) { r in
                                    NavigationLink { RuleEditorView(ruleId: r.id) } label: { RuleRow(rule: r) }
                                }
                                .onDelete { idx in idx.map { local[$0].id }.forEach(model.deleteRule) }
                            }
                        }
                        if !server.isEmpty {
                            Section {
                                ForEach(server) { r in
                                    NavigationLink { RuleDetailView(rule: r) } label: { RuleRow(rule: r) }
                                }
                            } header: { Text("Managed by your admin") }
                        }
                    }
                }
            }
            .navigationTitle("Schedules")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New schedule").disabled(!model.allowLocalRules)
                }
            }
            .sheet(isPresented: $showNew) { NavigationStack { RuleEditorView(ruleId: nil) } }
        }
    }
}

struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name).font(.headline)
                    if rule.source == .server { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Managed by server") }
                    if rule.strictness == .strict { Text("Strict").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2))) }
                }
                Text(RuleSummary.describe(rule)).font(.subheadline).foregroundStyle(.secondary)
                Text(rule.groupIds.compactMap { model.group($0)?.name }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if rule.source == .local {
                Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { model.setRuleEnabled(rule.id, $0) }))
                    .labelsHidden()
            } else if !rule.enabled {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RuleDetailView: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    var body: some View {
        List {
            Section { Label("Managed by your admin. You can't change this.", systemImage: "lock.fill").font(.subheadline) }
            Section("When") { Text(RuleSummary.describe(rule)) }
            Section("Groups") { ForEach(rule.groupIds, id: \.self) { Text(model.group($0)?.name ?? $0) } }
            Section("Strictness") {
                Text(rule.strictness == .strict ? "Strict — can't be paused" : "Flexible — can be paused")
                if let m = rule.maxPausesPerDay { Text("Up to \(m) pauses per day") }
            }
        }
        .navigationTitle(rule.name).navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Schedules") { RulesView().environment(AppModel.preview()) }
