import SwiftUI
import FamilyControls
import TetherCore

struct GroupsView: View {
    @Environment(AppModel.self) private var model
    @State private var showNew = false

    private var local: [BlockGroup] { model.allGroups.filter { $0.source == .local } }
    private var server: [BlockGroup] { model.allGroups.filter { $0.source == .server } }

    var body: some View {
        NavigationStack {
            Group {
                if model.allGroups.isEmpty {
                    EmptyState(icon: "square.grid.2x2", title: "No groups yet",
                               message: "A group is a set of apps, categories and websites you want to block together.",
                               actionTitle: "Create a group") { showNew = true }
                } else {
                    List {
                        if !local.isEmpty {
                            Section("Yours") {
                                ForEach(local) { g in
                                    NavigationLink { GroupEditorView(groupId: g.id) } label: { GroupRow(group: g) }
                                }
                                .onDelete { idx in idx.map { local[$0].id }.forEach(model.deleteGroup) }
                            }
                        }
                        if !server.isEmpty {
                            Section {
                                ForEach(server) { g in
                                    NavigationLink { ServerGroupView(groupId: g.id) } label: { GroupRow(group: g) }
                                }
                            } header: { Text("Managed by your admin") } footer: {
                                Text("Names and websites are set by your admin. Apps are chosen on this device.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("New group")
                }
            }
            .sheet(isPresented: $showNew) { NavigationStack { GroupEditorView(groupId: nil, presentation: .sheet) } }
        }
    }
}

struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: BlockGroup
    var body: some View {
        let sel = model.selection(for: group.id)
        HStack(spacing: 12) {
            Circle().fill(Color(hex: group.colorHex)).frame(width: 14, height: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(group.name).font(.headline)
                    if group.source == .server { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                }
                Text(summary(sel)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private func summary(_ s: FamilyActivitySelection) -> String {
        var parts: [String] = []
        if !s.applicationTokens.isEmpty { parts.append("\(s.applicationTokens.count) app\(s.applicationTokens.count == 1 ? "" : "s")") }
        if !s.categoryTokens.isEmpty { parts.append("\(s.categoryTokens.count) categor\(s.categoryTokens.count == 1 ? "y" : "ies")") }
        let web = s.webDomainTokens.count + group.webDomains.count
        if web > 0 { parts.append("\(web) site\(web == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing selected yet" : parts.joined(separator: ", ")
    }
}

#Preview("Groups") { GroupsView().environment(AppModel.preview()) }
