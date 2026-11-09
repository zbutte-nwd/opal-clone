import SwiftUI
import TetherCore

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showStart = false
    @State private var presetMinutes = 25
    @State private var pauseTarget: PauseTarget?
    @State private var mapTarget: BlockGroup?

    struct PauseTarget: Identifiable { let id: GroupID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    protectionBanner
                    ForEach(model.unmappedServerGroups.prefix(3)) { g in
                        StatusBanner(style: .info, title: "Choose apps for “\(g.name)”",
                                     message: "Added by your admin. Pick which apps and sites on this device belong to it.",
                                     actionTitle: "Choose apps") { mapTarget = g }
                    }
                    if let session = model.activeSession {
                        SessionCard(session: session, onPause: { pauseTarget = PauseTarget(id: session.groupIds.first ?? "") })
                    }
                    blockedSection
                    quickStart
                    nextBlockCard
                }
                .padding()
            }
            .navigationTitle("Tether")
            .refreshable { await model.syncNow() }
            .sheet(isPresented: $showStart) { NavigationStack { StartSessionView(initialMinutes: presetMinutes) } }
            .sheet(item: $pauseTarget) { t in NavigationStack { PauseFlowView(groupId: t.id.isEmpty ? nil : t.id) } }
            .sheet(item: $mapTarget) { g in NavigationStack { ServerGroupView(groupId: g.id) } }
        }
    }

    // MARK: Sections

    @ViewBuilder private var protectionBanner: some View {
        switch model.protectionStatus {
        case .protected:
            StatusBanner(style: .ok, title: "Protected", message: "Screen Time access is on and protection is locked with \(lockName).")
        case .notProtected:
            StatusBanner(style: .warning, title: "Not protected", message: "Blocking works, but the Protection Lock is off, so anyone can change settings here.")
        case .authorizationRevoked:
            StatusBanner(style: .error, title: "Screen Time access was revoked",
                         message: "Nothing is being blocked. Allow Tether again in Settings → Screen Time. Your admin has been notified if you're paired.")
        case .needsAuthorization:
            StatusBanner(style: .warning, title: "Screen Time access needed", message: "Open Settings → Screen Time access to allow Tether.")
        }
    }

    private var lockName: String {
        switch model.protectionLock {
        case .partnerPIN: return "a partner PIN"
        case .remoteApproval: return "remote approval"
        case .osOnly: return "iOS Screen Time"
        }
    }

    private var blockedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blocked now").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            if model.blockedItems.isEmpty {
                Text("Nothing is blocked right now.").foregroundStyle(.secondary).card()
            } else {
                ForEach(model.blockedItems) { item in
                    BlockedGroupCard(item: item) { pauseTarget = PauseTarget(id: item.id) }
                }
            }
        }
    }

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a focus session").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                ForEach([25, 50, 90], id: \.self) { m in
                    Button("\(m) min") { presetMinutes = m; showStart = true }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                Button("Custom") { presetMinutes = 30; showStart = true }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    @ViewBuilder private var nextBlockCard: some View {
        if let nb = model.nextBlock {
            let names = nb.groupIds.compactMap { model.group($0)?.name }.joined(separator: ", ")
            HStack(spacing: 12) {
                Image(systemName: "clock").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Next block").font(.headline)
                    Text("\(names) at \(Fmt.until(nb.date, now: model.now))").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .card().accessibilityElement(children: .combine)
        }
    }
}

struct BlockedGroupCard: View {
    @Environment(AppModel.self) private var model
    let item: BlockedItem
    var onPause: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3).fill(Color(hex: item.group.colorHex)).frame(width: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.group.name).font(.headline)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.state.strict {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("Strict, cannot be paused")
            } else {
                Button("Pause", action: onPause).buttonStyle(.bordered)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct SessionCard: View {
    @Environment(AppModel.self) private var model
    let session: FocusSession
    var onPause: () -> Void

    var body: some View {
        let total = session.endsAt.timeIntervalSince(session.startsAt)
        let elapsed = model.now.timeIntervalSince(session.startsAt)
        let remaining = max(0, session.endsAt.timeIntervalSince(model.now))
        VStack(spacing: 14) {
            HStack {
                Text(session.name ?? "Focus session").font(.headline)
                if session.strict { Label("Deep Focus", systemImage: "lock.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                Spacer()
            }
            CountdownRing(progress: total > 0 ? elapsed / total : 1) {
                VStack {
                    Text(Fmt.duration(seconds: remaining)).font(.system(.largeTitle, design: .rounded).monospacedDigit().bold())
                    Text("remaining").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 180, height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Time remaining")
            .accessibilityValue(Fmt.duration(seconds: remaining))
            Text(session.groupIds.compactMap { model.group($0)?.name }.joined(separator: ", "))
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("End session", role: .destructive) { model.endSession(session.id) }
                    .buttonStyle(.bordered).disabled(session.strict)
                if !session.strict { Button("Pause", action: onPause).buttonStyle(.bordered) }
            }
            if session.strict {
                Text("Deep Focus can't be ended or paused early.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .card()
        .frame(maxWidth: .infinity)
    }
}

#Preview("Home") {
    HomeView().environment(AppModel.preview())
}
