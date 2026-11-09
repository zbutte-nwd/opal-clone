import SwiftUI
import TetherCore
import TetherAPI

/// E2 pairing UX: enter a code (or arrive via tether://pair), see server/device, sync, unpair.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var prefillCode: String?
    var prefillServer: URL?

    @State private var code = ""
    @State private var serverText = ""
    @State private var busy = false
    @State private var confirmUnpair = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            if let server = model.state.server { pairedSection(server) } else { enterSection }
        }
        .navigationTitle("Remote control")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Unpair from the server?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { Task { await model.unpair() } }
        }
        .toolbar { if prefillCode != nil || prefillServer != nil {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } } }
        .onAppear {
            if let c = prefillCode, code.isEmpty { code = c }
            if let s = prefillServer, serverText.isEmpty { serverText = s.absoluteString; showAdvanced = true }
        }
    }

    // MARK: Not paired

    @ViewBuilder private var enterSection: some View {
        Section {
            TextField("K7Q2-M9XD", text: Binding(get: { code }, set: { code = Self.format($0) }))
                .font(.title2.monospaced())
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .accessibilityLabel("Pairing code")
        } header: { Text("Pairing code") } footer: {
            Text("Get a code from your admin dashboard (Devices → Add device), or open the pairing link on this phone.")
        }
        Section {
            DisclosureGroup("Server address", isExpanded: $showAdvanced) {
                TextField(model.platform.defaultServerURL?.absoluteString ?? "https://your-server.example", text: $serverText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            }
        }
        Section {
            Button {
                busy = true
                Task {
                    let ok = await model.pair(code: code, server: URL(string: serverText.trimmingCharacters(in: .whitespaces)))
                    busy = false
                    if ok && (prefillCode != nil || prefillServer != nil) { dismiss() }
                }
            } label: {
                HStack { if busy { ProgressView() }; Text("Pair this device").fontWeight(.semibold) }.frame(maxWidth: .infinity)
            }
            .disabled(busy || code.filter { $0.isLetter || $0.isNumber }.count < 8)
        } footer: {
            Text("Pairing lets an admin set groups and schedules, block or unblock remotely, and see whether Tether is switched on. They never see which apps you use.")
        }
    }

    // MARK: Paired

    @ViewBuilder private func pairedSection(_ server: ServerConfig) -> some View {
        Section("This device") {
            LabeledContent("Server", value: server.baseURL.host ?? server.baseURL.absoluteString)
            LabeledContent("Device ID") { Text(server.deviceId).font(.footnote.monospaced()).textSelection(.enabled) }
            LabeledContent("Policy version", value: model.state.bundle.map { "\($0.version)" } ?? "none yet")
            LabeledContent("Last sync", value: model.state.lastSyncAt.map { Fmt.relative($0) } ?? "never")
        }
        Section {
            Button {
                Task { await model.syncNow() }
            } label: { HStack { if model.isSyncing { ProgressView() }; Text("Sync now") } }
            .disabled(model.isSyncing)
            if let msg = model.lastSync?.message { Text(msg).font(.footnote).foregroundStyle(.orange) }
        }
        Section {
            Button("Unpair this device", role: .destructive) { confirmUnpair = true }
                .disabled(model.state.protection.enabled)
        } footer: {
            Text(model.state.protection.enabled
                 ? "Turn off protection first (Settings → Protection Lock). Otherwise pairing couldn't be used to dodge a block."
                 : "Removes the connection to the server. Groups and schedules it managed will disappear from this device.")
        }
    }

    /// Uppercases, keeps A–Z/0–9 and inserts a dash after 4 characters (max 8).
    static func format(_ raw: String) -> String {
        let chars = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8)
        guard chars.count > 4 else { return String(chars) }
        return String(chars.prefix(4)) + "-" + String(chars.dropFirst(4))
    }
}

#Preview("Pairing - paired") { NavigationStack { PairingView() }.environment(AppModel.preview()) }
