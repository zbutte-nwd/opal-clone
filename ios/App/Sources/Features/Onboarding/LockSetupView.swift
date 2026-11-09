import SwiftUI
import TetherCore

/// Protection Lock chooser + PIN creation. Used by onboarding and Settings → Protection.
struct LockSetupView: View {
    @Environment(AppModel.self) private var model
    var primaryTitle: String = "Turn on protection"
    var onDone: () -> Void

    private enum Phase { case choose, enterPIN, confirmPIN }
    @State private var lock: ProtectionLock = .partnerPIN
    @State private var phase: Phase = .choose
    @State private var pin = ""
    @State private var firstPIN = ""
    @State private var pinError: String?

    var body: some View {
        switch phase {
        case .choose:
            StepScaffold(title: "Protection Lock",
                         subtitle: "Decide what it takes to switch Tether off from inside the app. None of these use Face ID or Touch ID.",
                         primaryTitle: lock == .partnerPIN ? "Continue" : primaryTitle,
                         primaryAction: chooseDone) {
                row(.partnerPIN, "Partner PIN (recommended)",
                    "A 6–8 digit PIN is needed to disable protection. Ideally someone you trust sets it and keeps it. Using the same number as your Screen Time passcode means one secret protects everything.")
                row(.remoteApproval, "Remote approval",
                    "Disabling protection needs an admin to approve it on the Tether dashboard. Requires pairing this device with a server.")
                row(.osOnly, "iOS only",
                    "Tether offers no way to switch itself off. To stop blocking you must revoke Tether in Settings → Screen Time, which needs your Screen Time passcode. If nobody knows that passcode you could be locked out.")
                Text("Be aware: iOS does not let an app check the Screen Time passcode. Only iOS itself can enforce it, so the passcode protects Tether at the OS level, while this lock protects the in-app controls.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .enterPIN:
            pinScreen(title: "Create the Tether PIN", subtitle: "Choose 6–8 digits. Hand the device to your partner now if they should hold the PIN, and use the same number as the Screen Time passcode you'll set next.",
                      button: "Next") {
                guard (6...8).contains(pin.count) else { pinError = "PIN must be 6–8 digits."; return }
                firstPIN = pin; pin = ""; pinError = nil; phase = .confirmPIN
            }
        case .confirmPIN:
            pinScreen(title: "Confirm the PIN", subtitle: "Enter the same PIN again.", button: primaryTitle) {
                guard pin == firstPIN else { pinError = "The PINs don't match. Try again."; pin = ""; return }
                finish(pin: pin)
            }
        }
    }

    private func pinScreen(title: String, subtitle: String, button: String, action: @escaping () -> Void) -> some View {
        StepScaffold(title: title, subtitle: subtitle, primaryTitle: button, primaryEnabled: pin.count >= 6,
                     secondaryTitle: "Back", secondaryAction: { pin = ""; firstPIN = ""; pinError = nil; phase = .choose },
                     primaryAction: action) {
            PINPad(pin: $pin, errorMessage: pinError).frame(maxWidth: .infinity)
        }
    }

    private func row(_ value: ProtectionLock, _ title: String, _ text: String) -> some View {
        Button { lock = value } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: lock == value ? "largecircle.fill.circle" : "circle").foregroundStyle(Color.accentColor).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }.card()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(lock == value ? .isSelected : [])
    }

    private func chooseDone() {
        if lock == .partnerPIN { phase = .enterPIN } else { finish(pin: nil) }
    }

    private func finish(pin: String?) {
        if model.enableProtection(lock: lock, pin: pin) { onDone() }
        else { phase = .choose }
    }
}

struct LockStep: View {
    var next: () -> Void
    var body: some View { LockSetupView(onDone: next) }
}
