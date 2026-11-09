import SwiftUI
import TetherCore
import TetherAPI

/// D1–D2, B4: pause a block with friction. Reached from Home or tether://pause?group=<id>.
struct PauseFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var groupId: GroupID?
    @State private var chosen: GroupID?
    @State private var secondsLeft = 10
    @State private var breathing = false
    @State private var countdownTask: Task<Void, Never>?
    @State private var askSent = false
    @State private var askBusy = false

    static let frictionSeconds = 10

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if candidates.isEmpty {
                    EmptyState(icon: "checkmark.circle", title: "Nothing to pause", message: "No groups are blocked right now.")
                } else {
                    if candidates.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Which group?").font(.headline)
                            ForEach(candidates) { g in
                                Button { select(g.id) } label: {
                                    GroupChip(group: g, selected: chosen == g.id)
                                }.buttonStyle(.plain)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let gid = chosen, let g = model.group(gid) { content(for: g) }
                }
            }
            .padding()
        }
        .navigationTitle("Pause")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onAppear {
            if chosen == nil { select(groupId.flatMap { id in candidates.first { $0.id == id }?.id } ?? candidates.first?.id) }
        }
        .onDisappear { countdownTask?.cancel() }
    }

    /// Groups currently blocked (the only ones worth pausing).
    private var candidates: [BlockGroup] { model.blockedItems.map(\.group) }

    @ViewBuilder private func content(for g: BlockGroup) -> some View {
        switch model.pauseEligibility(g.id) {
        case .allowed:
            if secondsLeft > 0 { breathingView(for: g) } else { optionsView(for: g) }
        case .notBlocked:
            Text("“\(g.name)” isn't blocked right now.").foregroundStyle(.secondary)
        case .strict:
            blocked(title: "This block is strict",
                    text: "“\(g.name)” is under a strict rule or Deep Focus session, so it can't be paused. It will end by itself\(untilText(g)).")
        case .budgetExhausted(let limit):
            blocked(title: "No pauses left today",
                    text: "You've used all \(limit) pause\(limit == 1 ? "" : "s") allowed today for this schedule. They reset at midnight.")
        }
    }

    private func untilText(_ g: BlockGroup) -> String {
        model.untilByGroup[g.id].map { " at \(Fmt.until($0, now: model.now))" } ?? ""
    }

    private func breathingView(for g: BlockGroup) -> some View {
        VStack(spacing: 20) {
            Text("Take a breath").font(.title2.bold())
            Text("Is pausing “\(g.name)” really what you want? Options unlock in a moment.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.2))
                    .frame(width: 180, height: 180)
                    .scaleEffect(reduceMotion ? 1 : (breathing ? 1.0 : 0.55))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 4).repeatForever(autoreverses: true), value: breathing)
                Text("\(secondsLeft)").font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Wait \(secondsLeft) seconds")
            Text(breathing ? "Breathe in… and out" : "").font(.callout).foregroundStyle(.secondary).hidden(false)
        }
        .padding(.top, 8)
    }

    private func optionsView(for g: BlockGroup) -> some View {
        VStack(spacing: 14) {
            Text("Pause “\(g.name)” for…").font(.title3.bold())
            ForEach([1, 5, 15], id: \.self) { m in
                Button { if model.startPause(groupId: g.id, minutes: m) { dismiss() } } label: {
                    Text("\(m) minute\(m == 1 ? "" : "s")").frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
            if model.protectionLock == .remoteApproval { askAdmin(for: g) }
            Button("Never mind, keep it blocked") { dismiss() }.padding(.top, 6)
        }
    }

    private func blocked(title: String, text: String) -> some View {
        VStack(spacing: 14) {
            StatusBanner(style: .info, title: title, message: text)
            if model.protectionLock == .remoteApproval, let gid = chosen, let g = model.group(gid) { askAdmin(for: g) }
        }
    }

    @ViewBuilder private func askAdmin(for g: BlockGroup) -> some View {
        if askSent {
            StatusBanner(style: .ok, title: "Request sent", message: "Your admin will get a notification. If they approve, “\(g.name)” unblocks automatically.")
        } else {
            Button {
                askBusy = true
                Task {
                    let id = await model.requestUnlock(kind: .groups, groupIds: [g.id], minutes: 15, reason: "Pause requested from device")
                    askBusy = false
                    askSent = id != nil
                }
            } label: {
                HStack { if askBusy { ProgressView() }; Label("Ask admin to unblock", systemImage: "person.badge.key") }
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered).controlSize(.large).disabled(askBusy || !model.isPaired)
            if !model.isPaired { Text("Pair with a server in Settings to ask an admin.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func select(_ id: GroupID?) {
        chosen = id
        countdownTask?.cancel()
        guard id != nil else { return }
        secondsLeft = Self.frictionSeconds
        breathing = false
        countdownTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            breathing = true
            while secondsLeft > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { secondsLeft -= 1 }
            }
        }
    }
}

private extension View {
    /// Keeps layout stable when text is empty.
    func hidden(_ flag: Bool) -> some View { self.opacity(flag ? 0 : 1) }
}

#Preview("Pause") {
    NavigationStack { PauseFlowView(groupId: "lgrp_social") }.environment(AppModel.preview())
}
