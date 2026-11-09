import SwiftUI
import FamilyControls
import TetherCore

/// Create / edit a LOCAL group (B1). `presentation: .onboarding` renders the step layout.
struct GroupEditorView: View {
    enum Presentation { case push, sheet, onboarding }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var groupId: GroupID?
    var presentation: Presentation = .push
    var onSaved: ((GroupID) -> Void)?

    @State private var name = ""
    @State private var colorHex = GroupPalette.hexes[0]
    @State private var selection = FamilyActivitySelection()
    @State private var domains: [String] = []
    @State private var newDomain = ""
    @State private var showPicker = false
    @State private var loaded = false
    @State private var domainError: String?
    @State private var guardTrigger = 0

    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        content.guardedChangePrompt(trigger: guardTrigger) {
            if let groupId { onSaved?(groupId) }
            if presentation != .onboarding { dismiss() }
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            if presentation == .onboarding {
                StepScaffold(title: "Your first group",
                             subtitle: "Choose the apps, categories and websites that distract you. Apple's picker keeps these choices private to this device.",
                             primaryTitle: "Save group", primaryEnabled: valid, primaryAction: save) {
                    formContent
                }
            } else {
                Form { formContent }
                    .navigationTitle(groupId == nil ? "New group" : "Edit group")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if presentation == .sheet {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        }
                        ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!valid) }
                    }
            }
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onAppear(perform: load)
    }

    @ViewBuilder private var formContent: some View {
        if presentation == .onboarding {
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder)
        } else {
            Section("Name") { TextField("e.g. Social, Games", text: $name) }
        }
        sectionWrap("Color") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(GroupPalette.hexes, id: \.self) { hex in
                        Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                            .overlay(Circle().stroke(Color.primary, lineWidth: colorHex == hex ? 3 : 0).padding(-3))
                            .onTapGesture { colorHex = hex }
                            .accessibilityLabel("Color \(hex)")
                            .accessibilityAddTraits(colorHex == hex ? [.isSelected, .isButton] : .isButton)
                    }
                }.padding(4)
            }
        }
        sectionWrap("Apps, categories & websites") {
            Button { showPicker = true } label: { Label("Choose apps and websites", systemImage: "apps.iphone") }
            SelectionSummary(selection: selection)
        }
        sectionWrap("Extra website domains") {
            ForEach(domains, id: \.self) { d in
                HStack { Text(d); Spacer()
                    Button { domains.removeAll { $0 == d } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        .accessibilityLabel("Remove \(d)")
                }
            }
            HStack {
                TextField("example.com", text: $newDomain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .onSubmit(addDomain)
                Button("Add", action: addDomain).disabled(newDomain.isEmpty)
            }
            if let domainError { Text(domainError).font(.footnote).foregroundStyle(.red) }
        }
    }

    /// Wraps content in a Form Section or a plain titled VStack depending on presentation.
    @ViewBuilder private func sectionWrap<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        if presentation == .onboarding {
            VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); content() }.card()
        } else {
            Section(title) { content() }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let gid = groupId, let g = model.group(gid) {
            name = g.name; colorHex = g.colorHex ?? colorHex; domains = g.webDomains
            selection = model.selection(for: gid)
        } else {
            colorHex = GroupPalette.nextHex(used: model.allGroups.map(\.colorHex))
            if presentation == .onboarding && name.isEmpty { name = "Distractions" }
        }
    }

    private func addDomain() {
        let d = Self.normalizeDomain(newDomain)
        guard let d else { domainError = "Enter a domain like example.com"; return }
        guard domains.count < 50 else { domainError = "At most 50 websites per group."; return }
        if !domains.contains(d) { domains.append(d) }
        newDomain = ""; domainError = nil
    }

    static func normalizeDomain(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        guard s.contains("."), !s.contains(" "), s.count >= 3 else { return nil }
        return s
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let gid = model.saveGroup(id: groupId, name: trimmed, colorHex: colorHex, domains: domains, selection: selection) {
            onSaved?(gid)
            if presentation != .onboarding { dismiss() }
        } else {
            guardTrigger += 1
        }
    }
}

#Preview("Group editor") {
    NavigationStack { GroupEditorView(groupId: "lgrp_social") }.environment(AppModel.preview())
}
