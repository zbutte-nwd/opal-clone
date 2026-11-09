import SwiftUI
import TetherCore

struct WelcomeStep: View {
    var next: () -> Void
    var body: some View {
        StepScaffold(title: "Welcome to Tether", subtitle: "Take back your attention. Block distracting apps and websites on a schedule, in focus sessions, or remotely from someone you trust.",
                     primaryTitle: "Get started", primaryAction: next) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 72)).foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity).padding(.vertical, 24).accessibilityHidden(true)
            Text("Tether never uses Face ID or Touch ID. Protection is backed by your Screen Time passcode and, optionally, a PIN that someone else holds.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct HowItWorksStep: View {
    var next: () -> Void
    var body: some View {
        StepScaffold(title: "How Tether works", primaryTitle: "Continue", primaryAction: next) {
            feature("calendar.badge.clock", "Schedules", "Block groups of apps and sites during work hours, bedtime, or any weekly window. Or set a daily usage limit.")
            feature("timer", "Focus sessions", "Start a 25, 50 or 90 minute session. Turn on Deep Focus to make it impossible to end early.")
            feature("antenna.radiowaves.left.and.right", "Remote control", "Pair with a Tether server and an admin (a parent, partner or employer) can block or unblock groups from a dashboard.")
        }
    }
    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 36).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PermissionStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: OnboardingDraft
    var next: () -> Void
    @State private var busy = false
    @State private var denied = false

    var body: some View {
        StepScaffold(title: "Screen Time access",
                     subtitle: "Tether uses Apple's Screen Time system to block apps. iOS will show its own permission prompt next, and you may be asked to authenticate with your device passcode. Tether never sees which apps you use; choices stay on this device.",
                     primaryTitle: denied ? "Try again" : "Allow Screen Time access",
                     primaryBusy: busy, secondaryTitle: denied ? "Continue without it" : nil,
                     secondaryAction: denied ? next : nil, primaryAction: request) {
            option(.individual, "Just me", "I manage my own device. Recommended for adults.")
            option(.child, "Managed by a parent (Family Sharing)",
                   "This device belongs to a child in a Family Sharing group. A guardian approves on their device and iOS itself stops the app being removed or switched off without their approval.")
            if denied {
                StatusBanner(style: .warning, title: "Access not granted",
                             message: "Without Screen Time access Tether can't block anything. You can retry, or allow it later in Settings → Screen Time.")
            }
        }
    }

    private func option(_ mode: AuthMode, _ title: String, _ text: String) -> some View {
        Button { draft.authMode = mode } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: draft.authMode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(Color.accentColor).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(draft.authMode == mode ? .isSelected : [])
    }

    private func request() {
        busy = true
        Task {
            let ok = await model.requestAuthorization(mode: draft.authMode)
            busy = false
            if ok { next() } else { denied = true }
        }
    }
}

#Preview("Permission") {
    PermissionStep(draft: OnboardingDraft(), next: {}).environment(AppModel.preview(onboarded: false))
}
