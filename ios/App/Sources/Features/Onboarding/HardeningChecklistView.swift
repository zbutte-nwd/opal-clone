import SwiftUI
import UIKit

/// A4: Screen Time passcode hardening guide. Reused by onboarding and Settings.
struct HardeningChecklistView: View {
    @Environment(AppModel.self) private var model

    static let items: [(key: String, title: String, detail: String)] = [
        ("passcode", "Set a Screen Time passcode",
         "Settings → Screen Time → Lock Screen Time Settings. Ideally your partner or guardian types it so you don't know it."),
        ("accountChanges", "Account Changes: Don't Allow",
         "Settings → Screen Time → Content & Privacy Restrictions → Account Changes → Don't Allow. This stops you signing out of iCloud, which would revoke Tether."),
        ("passcodeChanges", "Passcode Changes: Don't Allow",
         "Same menu → Passcode Changes → Don't Allow, so the Screen Time passcode can't be changed or removed from the Face ID/passcode screens.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.items, id: \.key) { item in
                let on = model.hardeningChecks.contains(item.key)
                Button { model.setHardeningCheck(item.key, on: !on) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .font(.title3).foregroundStyle(on ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline).foregroundStyle(.primary)
                            Text(item.detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            Text("I've done this").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        }
                        Spacer(minLength: 0)
                    }.card()
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint("Double tap to mark as done")
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: { Label("Open Settings", systemImage: "gearshape") }
                .buttonStyle(.bordered)
            Text("iOS only lets apps open their own page in Settings. From there, go back to the main Settings screen and choose Screen Time.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Why this matters: iOS only lets the Screen Time passcode protect Tether at the OS level. Tether cannot check or enforce that passcode itself, and it never uses Face ID.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct HardeningStep: View {
    var next: () -> Void
    var body: some View {
        StepScaffold(title: "Lock down Screen Time",
                     subtitle: "Tether's strongest protection is iOS's own Screen Time passcode. Do these three things in the Settings app.",
                     primaryTitle: "Continue", secondaryTitle: nil, primaryAction: next) {
            HardeningChecklistView()
        }
    }
}

#Preview {
    ScrollView { HardeningChecklistView().padding() }.environment(AppModel.preview())
}
