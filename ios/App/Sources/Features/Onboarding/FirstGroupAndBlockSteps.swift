import SwiftUI
import TetherCore
import UserNotifications

struct FirstGroupStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: OnboardingDraft
    var next: () -> Void

    var body: some View {
        GroupEditorView(groupId: draft.groupId, presentation: .onboarding) { gid in
            draft.groupId = gid
            next()
        }
    }
}

struct FirstBlockStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: OnboardingDraft
    var next: () -> Void

    var body: some View {
        StepScaffold(title: "Your first block", subtitle: "Pick a starting point. You can change or add more any time.",
                     primaryTitle: "Skip for now", primaryAction: next) {
            if let gid = draft.groupId {
                template("briefcase", "Weekday work hours 9–5", "Mon–Fri, 9:00 AM–5:00 PM") {
                    addRule(name: "Work hours", gid: gid, days: [1, 2, 3, 4, 5], start: "09:00", end: "17:00")
                }
                template("moon.zzz", "Bedtime 10 PM–7 AM", "Every night, 10:00 PM–7:00 AM") {
                    addRule(name: "Bedtime", gid: gid, days: [1, 2, 3, 4, 5, 6, 7], start: "22:00", end: "07:00")
                }
                template("timer", "Start a 25-minute focus session now", "Blocks right away for 25 minutes") {
                    if model.startSession(name: "First focus", groupIds: [gid], minutes: 25, strict: false) { next() }
                }
            } else {
                Text("Create a group first to add a block.").foregroundStyle(.secondary)
            }
        }
    }

    private func addRule(name: String, gid: GroupID, days: [Int], start: String, end: String) {
        let rule = Rule(id: TetherID.make("lrule"), name: name, groupIds: [gid],
                        trigger: .schedule(windows: [Window(days: days, start: start, end: end)]),
                        strictness: .flexible, maxPausesPerDay: 3)
        model.saveRule(rule)
        next()
    }

    private func template(_ icon: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 36).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.card()
        }
        .buttonStyle(.plain)
    }
}

struct DoneStep: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        StepScaffold(title: "You're set", subtitle: "Tether is ready.", primaryTitle: "Open Tether", primaryAction: finish) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 72)).foregroundStyle(.green)
                .frame(maxWidth: .infinity).padding(.vertical, 16).accessibilityHidden(true)
            Text("We'll ask to send notifications so you hear about changes your admin makes and when blocks begin.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Reminder: Tether never uses Face ID. If you skipped the Screen Time passcode steps you can finish them any time in Settings → Screen Time hardening.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func finish() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            model.completeOnboarding()
        }
    }
}
