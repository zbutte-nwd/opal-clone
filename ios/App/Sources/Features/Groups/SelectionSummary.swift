import SwiftUI
import FamilyControls
import ManagedSettings
import ManagedSettingsUI
import TetherCore

/// Shows counts and the token labels of a FamilyActivitySelection.
/// `Label(token)` renders the real app name/icon; it only works for tokens issued by the picker on a real device.
// VERIFY: Label(_: ApplicationToken) / Label(_: ActivityCategoryToken) / Label(_: WebDomainToken) live in
// FamilyControls (iOS 15+); the ManagedSettingsUI import is harmless if not needed.
struct SelectionSummary: View {
    let selection: FamilyActivitySelection
    private let limit = 12

    var body: some View {
        let apps = Array(selection.applicationTokens)
        let cats = Array(selection.categoryTokens)
        let webs = Array(selection.webDomainTokens)
        if apps.isEmpty && cats.isEmpty && webs.isEmpty {
            Text("Nothing selected yet").font(.footnote).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(apps.count) apps · \(cats.count) categories · \(webs.count) websites")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(apps.prefix(limit), id: \.self) { Label($0).labelStyle(.titleAndIcon) }
                ForEach(cats.prefix(limit), id: \.self) { Label($0).labelStyle(.titleAndIcon) }
                ForEach(webs.prefix(limit), id: \.self) { Label($0).labelStyle(.titleAndIcon) }
                let extra = max(0, apps.count - limit) + max(0, cats.count - limit) + max(0, webs.count - limit)
                if extra > 0 { Text("+ \(extra) more").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Read-only view of a server-defined group + local app mapping (B1).
struct ServerGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let groupId: GroupID
    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var loaded = false

    var body: some View {
        let g = model.group(groupId)
        Form {
            Section {
                HStack { Circle().fill(Color(hex: g?.colorHex)).frame(width: 14, height: 14)
                    Text(g?.name ?? "Group").font(.headline); Spacer(); Image(systemName: "lock.fill").foregroundStyle(.secondary) }
            } footer: { Text("Added by your admin. The name and websites can't be changed here.") }
            if let domains = g?.webDomains, !domains.isEmpty {
                Section("Websites (from your admin)") { ForEach(domains, id: \.self) { Text($0) } }
            }
            Section {
                Button { showPicker = true } label: { Label("Choose apps for “\(g?.name ?? "this group")”", systemImage: "apps.iphone") }
                SelectionSummary(selection: selection)
            } header: { Text("Apps on this device") } footer: {
                Text("Your admin can't see which apps you pick. They stay on this device.")
            }
        }
        .navigationTitle(g?.name ?? "Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { model.setSelection(selection, for: groupId); dismiss() }
            }
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onAppear { if !loaded { loaded = true; selection = model.selection(for: groupId) } }
    }
}
