import SwiftUI
import TetherCore

enum OnboardingStep: Int, CaseIterable {
    case welcome, how, permission, lock, hardening, group, block, done
}

/// State shared by the onboarding steps.
@MainActor @Observable
final class OnboardingDraft {
    var authMode: AuthMode = .individual
    var groupId: GroupID?
}

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @State private var step: OnboardingStep = .welcome
    @State private var draft = OnboardingDraft()

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome {
                HStack {
                    Button { back() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back")
                    ProgressView(value: Double(step.rawValue), total: Double(OnboardingStep.allCases.count - 1))
                        .accessibilityLabel("Setup progress")
                        .accessibilityValue("Step \(step.rawValue) of \(OnboardingStep.allCases.count - 1)")
                }
                .padding(.horizontal).padding(.top, 8)
            }
            Group {
                switch step {
                case .welcome: WelcomeStep(next: next)
                case .how: HowItWorksStep(next: next)
                case .permission: PermissionStep(draft: draft, next: next)
                case .lock: LockStep(next: next)
                case .hardening: HardeningStep(next: next)
                case .group: FirstGroupStep(draft: draft, next: next)
                case .block: FirstBlockStep(draft: draft, next: next)
                case .done: DoneStep()
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
        }
        .animation(.easeInOut, value: step)
    }

    private func next() {
        if let n = OnboardingStep(rawValue: step.rawValue + 1) { step = n }
    }
    private func back() {
        if let p = OnboardingStep(rawValue: step.rawValue - 1) { step = p }
    }
}

/// Common layout for a step: scrolling content + pinned primary button.
struct StepScaffold<Content: View>: View {
    var title: String
    var subtitle: String?
    var primaryTitle: String
    var primaryEnabled: Bool = true
    var primaryBusy: Bool = false
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    var primaryAction: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).font(.body).foregroundStyle(.secondary) }
                    content()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 8) {
                Button(action: primaryAction) {
                    HStack { if primaryBusy { ProgressView() }; Text(primaryTitle).fontWeight(.semibold) }
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!primaryEnabled || primaryBusy)
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction).controlSize(.large)
                }
            }
            .padding()
        }
    }
}

#Preview("Onboarding") {
    OnboardingFlow().environment(AppModel.preview(onboarded: false))
}
