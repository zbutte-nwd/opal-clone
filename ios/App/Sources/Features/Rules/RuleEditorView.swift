import SwiftUI
import TetherCore

struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var ruleId: RuleID?

    @State private var draft = RuleDraft()
    @State private var loaded = false
    @State private var showErrors = false

    var body: some View {
        Form {
            Section("Name") { TextField("e.g. Work hours", text: $draft.name) }

            Section("Groups to block") {
                if model.allGroups.isEmpty {
                    Text("Create a group first in the Groups tab.").foregroundStyle(.secondary)
                } else {
                    GroupChipPicker(groups: model.allGroups, selection: $draft.groupIds)
                }
            }

            Section("Type") {
                Picker("Trigger", selection: $draft.kind) {
                    ForEach(RuleDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }

            if draft.kind == .schedule {
                ForEach($draft.windows) { $w in
                    Section {
                        WeekdayPicker(days: $w.days)
                        DatePicker("Starts", selection: minutesBinding($w.startMin), displayedComponents: .hourAndMinute)
                        DatePicker("Ends", selection: minutesBinding($w.endMin), displayedComponents: .hourAndMinute)
                        if w.endsNextDay {
                            Label("Ends the next day", systemImage: "moon.stars").font(.footnote).foregroundStyle(.secondary)
                        }
                        if w.startMin == w.endMin {
                            Label("Start and end must differ", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                        }
                    } header: { Text("Time window") } footer: {
                        if draft.windows.count > 1 {
                            Button("Remove this window", role: .destructive) { draft.windows.removeAll { $0.id == w.id } }
                        }
                    }
                }
                Section { Button { draft.windows.append(WindowDraft()) } label: { Label("Add another window", systemImage: "plus") } }
            } else {
                Section {
                    Stepper(value: $draft.limitMinutes, in: 1...720, step: 5) {
                        Text("Limit: \(Fmt.duration(minutes: draft.limitMinutes)) a day").monospacedDigit()
                    }
                    WeekdayPicker(days: $draft.limitDays)
                } header: { Text("Daily limit") } footer: {
                    Text("Once you've spent this long on the group's apps in a day, they're blocked until midnight. Usage limits need apps or categories chosen in the group.")
                }
            }

            Section {
                Picker("Strictness", selection: $draft.strict) {
                    Text("Flexible — pausing allowed").tag(false)
                    Text("Strict — no pauses").tag(true)
                }
                if !draft.strict {
                    Toggle("Limit pauses per day", isOn: $draft.limitPauses)
                    if draft.limitPauses { Stepper("Max pauses: \(draft.maxPauses)", value: $draft.maxPauses, in: 0...20) }
                }
                Toggle("Enabled", isOn: $draft.enabled)
            } header: { Text("Strictness") } footer: {
                Text("A strict rule can't be paused, edited or turned off while it is blocking.")
            }

            if showErrors && !draft.errors.isEmpty {
                Section { ForEach(draft.errors, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.footnote) } }
            }
        }
        .navigationTitle(ruleId == nil ? "New schedule" : "Edit schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let id = ruleId, let r = model.state.localRules.first(where: { $0.id == id }), let d = RuleDraft(rule: r) { draft = d }
        }
    }

    private func save() {
        guard draft.errors.isEmpty else { showErrors = true; return }
        model.saveRule(draft.makeRule())
        dismiss()
    }

    /// Bridges minutes-since-midnight to the Date a DatePicker wants (today's date; only h:m matter).
    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                let cal = Calendar.current
                return cal.date(bySettingHour: (minutes.wrappedValue / 60) % 24, minute: minutes.wrappedValue % 60, second: 0,
                                of: cal.startOfDay(for: Date())) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

#Preview("Rule editor") {
    NavigationStack { RuleEditorView(ruleId: "lrule_work") }.environment(AppModel.preview())
}
