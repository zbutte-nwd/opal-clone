import SwiftUI

/// Presents what happens when a change touches an active guarded/strict schedule: a PIN sheet when the
/// change is held (`AppModel.pendingGuardedChange`, partnerPIN lock) or an alert when it was refused.
/// Each editing view owns its presentation (sheets can't be stacked from the root): after a mutation
/// returns false, bump `trigger`.
struct GuardedChangePrompt: ViewModifier {
    @Environment(AppModel.self) private var model
    let trigger: Int
    var onSuccess: () -> Void
    @State private var showPIN = false
    @State private var refusal: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) {
                if model.pendingGuardedChange != nil { showPIN = true }
                else if let e = model.lastError { refusal = e; model.lastError = nil }
            }
            .sheet(isPresented: $showPIN, onDismiss: { model.pendingGuardedChange = nil }) {
                NavigationStack { GuardedPINView { showPIN = false; onSuccess() } }
                    .presentationDetents([.medium])
            }
            .alert("Can't change this now", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(refusal ?? "") }
    }
}

extension View {
    func guardedChangePrompt(trigger: Int, onSuccess: @escaping () -> Void = {}) -> some View {
        modifier(GuardedChangePrompt(trigger: trigger, onSuccess: onSuccess))
    }
}

private struct GuardedPINView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onSuccess: () -> Void
    @State private var pin = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text(model.pendingGuardedChange?.reason ?? "")
                SecureField("Tether PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
            } footer: {
                Text("Your partner's PIN allows this one change. Wrong attempts count toward the same lockout as turning protection off.")
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("Schedule is active")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Allow change") {
                    if let e = model.confirmGuardedChange(pin: pin) { error = e; pin = "" } else { onSuccess() }
                }.disabled(pin.count < 6)
            }
        }
    }
}
