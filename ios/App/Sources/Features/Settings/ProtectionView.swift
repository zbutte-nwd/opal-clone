import SwiftUI
import UIKit
import TetherCore
import TetherAPI

struct ProtectionView: View {
    @Environment(AppModel.self) private var model
    @State private var showEnable = false
    @State private var showDisable = false
    @State private var showChangePIN = false

    var body: some View {
        Form {
            Section {
                let p = model.state.protection
                LabeledContent("Status", value: p.enabled ? "On" : "Off")
                LabeledContent("Lock", value: lockName)
                LabeledContent("Screen Time access", value: model.screenTimeAuth == .approved ? "Allowed" : "Not allowed")
                LabeledContent("Mode", value: p.authMode == .child ? "Managed by parent" : "Just me")
                if let at = p.enabledAt { LabeledContent("Turned on", value: at.formatted(date: .abbreviated, time: .shortened)) }
            }
            Section {
                if model.state.protection.enabled {
                    if model.protectionLock == .partnerPIN { Button("Change PIN") { showChangePIN = true } }
                    Button("Disable protection…", role: .destructive) { showDisable = true }
                } else {
                    Button("Turn on protection") { showEnable = true }
                }
            } footer: {
                Text("Tether never uses Face ID. Disabling in the app needs " + needs + " iOS also requires your Screen Time passcode to switch Tether off in Settings.")
            }
        }
        .navigationTitle("Protection Lock").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEnable) { LockSetupSheet() }
        .sheet(isPresented: $showDisable) { NavigationStack { DisableProtectionView() } }
        .sheet(isPresented: $showChangePIN) { NavigationStack { ChangePINView() } }
    }

    private var lockName: String {
        switch model.protectionLock {
        case .partnerPIN: return "Partner PIN"
        case .remoteApproval: return "Remote approval"
        case .osOnly: return "iOS only"
        }
    }
    private var needs: String {
        switch model.protectionLock {
        case .partnerPIN: return "the partner PIN."
        case .remoteApproval: return "admin approval."
        case .osOnly: return "nothing in the app: it can only be done in iOS Settings."
        }
    }
}

private struct LockSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { LockSetupView(onDone: { dismiss() }) }
}

// MARK: - Disable (A7)

struct DisableProtectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var error: String?
    @State private var requestId: String?
    @State private var status: UnlockStatus?
    @State private var pollTask: Task<Void, Never>?
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Disable protection").font(.largeTitle.bold())
                switch model.protectionLock {
                case .partnerPIN: pinBody
                case .remoteApproval: remoteBody
                case .osOnly: osBody
                }
            }
            .padding()
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .onDisappear { pollTask?.cancel() }
    }

    private var pinBody: some View {
        VStack(spacing: 16) {
            Text("Ask your partner to enter the Tether PIN. Disabling clears all blocks on this device and notifies your admin if you're paired.")
                .foregroundStyle(.secondary)
            PINPad(pin: $pin, errorMessage: error).frame(maxWidth: .infinity)
            Button(role: .destructive) { attempt() } label: { Text("Disable protection").frame(maxWidth: .infinity, minHeight: 28) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(pin.count < 6)
        }
    }

    private func attempt() {
        if let e = model.disableProtection(pin: pin) { error = e; pin = "" } else { dismiss() }
    }

    private var remoteBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("An admin must approve this on the Tether dashboard. Blocking stays on until they do.").foregroundStyle(.secondary)
            if !model.isPaired { StatusBanner(style: .warning, title: "Not paired", message: "Pair this device with a server first.") }
            switch status {
            case .none:
                Button { send() } label: { HStack { if busy { ProgressView() }; Text("Ask admin to approve").frame(maxWidth: .infinity, minHeight: 28) } }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy || !model.isPaired)
            case .pending:
                StatusBanner(style: .info, title: "Waiting for approval…", message: "We'll check every few seconds. You can close this screen and come back.")
                ProgressView()
            case .approved:
                StatusBanner(style: .ok, title: "Approved", message: "Protection has been disabled.")
            case .denied:
                StatusBanner(style: .error, title: "Request denied", message: "Your admin declined. Protection stays on.")
                Button("Ask again") { status = nil; requestId = nil }
            case .expired:
                StatusBanner(style: .warning, title: "Request expired", message: "Nobody responded in time.")
                Button("Ask again") { status = nil; requestId = nil }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private func send() {
        busy = true; error = nil
        Task {
            let id = await model.requestUnlock(kind: .disableProtection, groupIds: [], minutes: nil, reason: "Disable protection requested on device")
            busy = false
            guard let id else { return }
            requestId = id; status = .pending
            poll(id)
        }
    }

    private func poll(_ id: String) {
        pollTask?.cancel()
        pollTask = Task {
            var attempts = 0
            while !Task.isCancelled && attempts < 200 {
                try? await Task.sleep(for: .seconds(3))
                attempts += 1
                guard let s = try? await model.platform.unlockRequestStatus(id: id) else { continue }
                status = s
                if s == .approved {
                    if let e = model.completeRemoteDisable(requestId: id) { error = e }
                    return
                }
                if s != .pending { return }
            }
        }
    }

    private var osBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusBanner(style: .info, title: "iOS only", message: "You chose a lock that has no in-app off switch.")
            Text("To stop Tether blocking, open Settings → Screen Time, find Tether under apps with Screen Time access, and turn it off. iOS will ask for your Screen Time passcode.")
            Text("Tether can't check that passcode itself, and never uses Face ID.").font(.footnote).foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.buttonStyle(.bordered)
        }
    }
}

// MARK: - Change PIN

struct ChangePINView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private enum Phase { case old, new, confirm }
    @State private var phase: Phase = .old
    @State private var pin = ""
    @State private var oldPIN = ""
    @State private var newPIN = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.title2.bold()).padding(.top)
            PINPad(pin: $pin, errorMessage: error)
            Button(phase == .confirm ? "Change PIN" : "Next") { advance() }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(pin.count < 6)
            Spacer()
        }
        .padding()
        .navigationTitle("Change PIN").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private var title: String {
        switch phase {
        case .old: return "Enter the current PIN"
        case .new: return "Enter a new PIN (6–8 digits)"
        case .confirm: return "Confirm the new PIN"
        }
    }

    private func advance() {
        error = nil
        switch phase {
        case .old: oldPIN = pin; pin = ""; phase = .new
        case .new: newPIN = pin; pin = ""; phase = .confirm
        case .confirm:
            guard pin == newPIN else { error = "The PINs don't match."; pin = ""; phase = .new; return }
            if let e = model.changePIN(old: oldPIN, new: newPIN) { error = e; pin = ""; phase = .old } else { dismiss() }
        }
    }
}

#Preview("Protection") { NavigationStack { ProtectionView() }.environment(AppModel.preview()) }
#Preview("Disable") { NavigationStack { DisableProtectionView() }.environment(AppModel.preview()) }
