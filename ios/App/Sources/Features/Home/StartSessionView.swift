import SwiftUI
import TetherCore

struct StartSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initialMinutes: Int = 25

    @State private var minutes: Int = 25
    @State private var selected: Set<GroupID> = []
    @State private var strict = false
    @State private var name = ""
    @State private var confirmStrict = false

    var body: some View {
        Form {
            Section("Duration") {
                HStack {
                    ForEach([25, 50, 90], id: \.self) { m in
                        Button("\(m)") { minutes = m }
                            .buttonStyle(.bordered).tint(minutes == m ? .accentColor : .secondary)
                            .accessibilityLabel("\(m) minutes")
                    }
                }
                Stepper(value: $minutes, in: 5...480, step: 5) {
                    Text("Custom: \(Fmt.duration(minutes: minutes))").monospacedDigit()
                }
            }
            Section("Block these groups") {
                if model.allGroups.isEmpty {
                    Text("Create a group first in the Groups tab.").foregroundStyle(.secondary)
                } else {
                    GroupChipPicker(groups: model.allGroups, selection: $selected)
                }
            }
            Section("Name (optional)") { TextField("e.g. Deep work", text: $name) }
            Section {
                Toggle("Deep Focus — can't end early", isOn: $strict)
            } footer: {
                Text("While Deep Focus is on you can't end or pause the session, even if you delete the group. It ends only when the timer does.")
            }
        }
        .navigationTitle("Focus session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") { strict ? (confirmStrict = true) : start() }.disabled(selected.isEmpty)
            }
        }
        .confirmationDialog("Start Deep Focus for \(Fmt.duration(minutes: minutes))?", isPresented: $confirmStrict, titleVisibility: .visible) {
            Button("Start — I can't stop it early", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            minutes = initialMinutes
            if selected.isEmpty { selected = Set(model.allGroups.prefix(1).map(\.id)) }
        }
    }

    private func start() {
        if model.startSession(name: name, groupIds: Array(selected), minutes: minutes, strict: strict) { dismiss() }
    }
}

#Preview {
    NavigationStack { StartSessionView() }.environment(AppModel.preview())
}
