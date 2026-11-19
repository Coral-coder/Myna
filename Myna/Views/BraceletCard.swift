import SwiftUI
import UIKit

/// Backstage card: pair and watch the Bee bracelet — your own device, your own
/// key. Shows connection state, battery, firmware and the audio codec, and
/// explains the one manual step (a factory reset) for a bracelet that's sealed
/// with a key Myna doesn't hold.
struct BraceletCard: View {
    @EnvironmentObject private var bee: BeeManager
    @State private var brightness: Double = 128
    @State private var editingBrightness = false
    @State private var pastedKey = ""
    @State private var showKeyPaste = false
    @State private var showServerFetch = false
    @State private var fetchHost = "api.beeai-services.com"
    @State private var fetchProof = ""
    @State private var fetchSecret = ""
    @State private var fetchToken = ""
    @State private var showAccountFetch = false
    @State private var showOwnKeyTest = false
    @State private var acctSessionToken = ""
    @State private var acctPassphrase = ""
    @State private var acctProof = ""
    @State private var acctSecret = ""
    @State private var showLab = false
    @State private var labHex = ""
    private let bitrateOptions = [16000, 24000, 32000, 64000, 128000]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: "wave.3.right.circle.fill", title: "Bee Bracelet", tint: MynaTheme.cyan)
            Text("Myna talks to your Bee bracelet directly over Bluetooth and brings its audio in on this iPhone — using a key Myna generates and installs on the bracelet itself. Nothing is uploaded.")
                .braceletCaption()

            Toggle(isOn: Binding(
                get: { bee.isEnabled },
                set: { on in on ? bee.enable() : bee.disable() }
            )) {
                Text("Use my Bee bracelet").braceletLabel()
            }
            .tint(MynaTheme.cyan)

            if bee.isEnabled {
                statusRow
                if let codec = bee.codec {
                    detailRow(icon: "waveform", text: "Audio codec: \(codec.description)")
                }
                if let firmware = bee.firmware {
                    detailRow(icon: "cpu", text: "Firmware \(firmware)")
                }
                if !bee.deviceID.isEmpty {
                    detailRow(icon: "number", text: "Device \(bee.deviceID.prefix(8))")
                }
                pairingDetail
                capturedKeySection
                accountFetchSection
                serverFetchSection
                ownKeyTestSection
                if bee.isReadyForControl, bee.deviceState == .mute {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow(icon: "mic.slash.fill", text: "The bracelet is muted, so it isn't sending audio.", tint: MynaTheme.gold)
                        Button("Unmute bracelet") { bee.setRecording(true) }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .tint(MynaTheme.cyan)
                    }
                }
                if bee.isReadyForControl { controlsSection }
                if bee.isReadyForControl { labSection }
                VStack(alignment: .leading, spacing: 6) {
                    Button("Remove bracelet & sync from Bee") { bee.removeAndSync() }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .tint(MynaTheme.gold)
                    Text("Stop trying to pair the bracelet directly and pull your conversations from Bee's cloud instead.")
                        .braceletCaption()
                }
                if !bee.diagnostics.isEmpty { deviceLog }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.cyan)
        .onAppear(perform: prefillSavedLogin)
    }

    /// Show the Bee login Myna already has saved, so the user can see it's
    /// remembered and re-fetch or edit it without re-typing everything.
    private func prefillSavedLogin() {
        let saved = bee.savedBeeLogin
        // Prefer a pasted token, else show the token from the linked Bee account.
        if acctSessionToken.isEmpty { acctSessionToken = saved.sessionToken.isEmpty ? (bee.effectiveSessionToken() ?? "") : saved.sessionToken }
        if acctPassphrase.isEmpty { acctPassphrase = saved.passphrase }
        if acctProof.isEmpty { acctProof = saved.proof }
        if acctSecret.isEmpty { acctSecret = saved.secret }
    }

    /// Paste a Bee-signed key token captured from the bracelet's BLE pairing
    /// (the SetEncryptionKey 0xC018 write), so Myna can decrypt audio with no
    /// Bee server. See the flasher/README for how to capture it.
    @ViewBuilder
    private var capturedKeySection: some View {
        DisclosureGroup(isExpanded: $showKeyPaste) {
            VStack(alignment: .leading, spacing: 8) {
                if let keyHex = bee.exportableKeyHex {
                    Text("Key held: \(bee.exportableKeyLabel)").braceletCaption()
                    Text(keyHex)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MynaTheme.ink.opacity(0.75))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy key") { UIPasteboard.general.string = keyHex }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .tint(MynaTheme.cyan)
                    Divider().overlay(MynaTheme.ink.opacity(0.1))
                }
                Text("Paste the bytes from the bracelet's SetEncryptionKey write (the value after 18 C0, 108 bytes as hex). Myna stores it on-device and uses it to decrypt audio — no Bee server.")
                    .braceletCaption()
                TextField("18c0… or the 108-byte hex", text: $pastedKey, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MynaTheme.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MynaTheme.ink.opacity(0.06)))
                Button("Save key & reconnect") {
                    bee.setCapturedKeyToken(pastedKey)
                    pastedKey = ""
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tint(MynaTheme.cyan)
                .disabled(pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 6)
        } label: {
            Text("Advanced: paste captured key").braceletLabel()
        }
        .tint(MynaTheme.ink.opacity(0.6))
    }

    /// The experiment that settles whether a Bee-free key generator is possible:
    /// install our OWN randomly generated key (wrapped in a real captured
    /// envelope) on a factory-reset bracelet and see whether the firmware takes
    /// it. Accepted → the key isn't signature-bound, so Myna can mint its own.
    @ViewBuilder
    private var ownKeyTestSection: some View {
        DisclosureGroup(isExpanded: $showOwnKeyTest) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Settles whether Myna can generate its own bracelet key instead of ever asking Bee. It puts a key Myna made itself onto the bracelet, wrapped in a real captured envelope, and checks whether the firmware accepts it.")
                    .braceletCaption()
                Text("Tap Arm, then factory-reset the bracelet on the device (press its button 5× until blue+green). Myna stops its normal setup so the reset bracelet stays unsealed, and runs the test by itself the moment it reconnects — no race, no timing. Rejected → nothing changed, set up normally. Accepted → the bracelet runs your own key from then on.")
                    .braceletCaption()
                if let result = bee.ownKeyTestResult {
                    Text(result)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(MynaTheme.ink.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    bee.armOwnKeyTest()
                } label: {
                    HStack(spacing: 8) {
                        if bee.ownKeyTestRunning { ProgressView().controlSize(.small).tint(MynaTheme.cyan) }
                        Text(bee.ownKeyTestRunning ? "Testing…"
                             : (bee.ownKeyTestArmed ? "Armed — waiting for reset (tap to cancel)" : "Arm the test"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                }
                .tint(bee.ownKeyTestArmed ? MynaTheme.magenta : MynaTheme.cyan)
                .disabled(bee.ownKeyTestRunning || !bee.canRunOwnKeyTest)
                if !bee.canRunOwnKeyTest {
                    Text("Capture your real Bee key first (above), then this unlocks.")
                        .braceletCaption()
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Advanced: test my own key (experimental)").braceletLabel()
        }
        .tint(MynaTheme.ink.opacity(0.6))
    }

    /// The full in-app path: Myna reproduces the Bee app's account auth from a
    /// durable session token + your recovery passphrase, derives proof/secret
    /// itself, and fetches the key. Only the session token is captured (once).
    @ViewBuilder
    private var accountFetchSection: some View {
        DisclosureGroup(isExpanded: $showAccountFetch) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Myna makes the exact call the Bee app does, using your recovery passphrase to derive the account keys. If your Bee account is linked above (for conversation import), Myna uses that token automatically — just enter your recovery passphrase once and tap Fetch; after that it re-fetches the key on its own each connect. If you haven't linked Bee, paste a session token (the x-bee-token header from a Bee app request) as well. Everything stays on-device.")
                    .braceletCaption()
                if bee.canAutoFetchKey {
                    detailRow(icon: "checkmark.seal.fill", text: "Bee login saved — Myna fetches the key automatically on connect.", tint: MynaTheme.cyan)
                } else if bee.hasSavedBeeLogin {
                    detailRow(icon: "exclamationmark.triangle.fill", text: "Passphrase saved, but no session token yet — link your Bee account above, or paste a token.", tint: MynaTheme.gold)
                }
                fetchField("x-bee-token (paste from a Bee app request)", text: $acctSessionToken)
                Text("Option A — recovery passphrase:").braceletCaption()
                fetchField("recovery passphrase (your BIP39 words)", text: $acctPassphrase)
                Text("Option B — paste proof + secret from the same request:").braceletCaption()
                fetchField("x-bee-proof", text: $acctProof)
                fetchField("x-bee-secret", text: $acctSecret)
                Button("Save & fetch key with my Bee login") {
                    if !acctPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        bee.fetchKeyFromBeeAccount(sessionToken: acctSessionToken, passphrase: acctPassphrase)
                    } else {
                        bee.fetchKeyFromBeeAccount(sessionToken: acctSessionToken, proof: acctProof, secret: acctSecret)
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tint(MynaTheme.cyan)
                .disabled(accountFetchDisabled)
                if bee.hasSavedBeeLogin {
                    Button("Forget saved Bee login") {
                        bee.forgetBeeAccount()
                        acctSessionToken = ""; acctPassphrase = ""; acctProof = ""; acctSecret = ""
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tint(MynaTheme.gold)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Advanced: fetch key with Bee login").braceletLabel()
        }
        .tint(MynaTheme.ink.opacity(0.6))
    }

    private var accountFetchDisabled: Bool {
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if bee.deviceID.isEmpty || blank(acctSessionToken) { return true }
        let hasPassphrase = !blank(acctPassphrase)
        let hasProofSecret = !blank(acctProof) && !blank(acctSecret)
        return !(hasPassphrase || hasProofSecret)
    }

    /// Fetch the sealed key from Bee's backend the way the app does, by sending
    /// the account auth headers. Captured once from any Bee request, they let
    /// Myna pull the key with no BLE capture and no factory reset.
    @ViewBuilder
    private var serverFetchSection: some View {
        DisclosureGroup(isExpanded: $showServerFetch) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Myna calls Bee's /ble/secure-key as the app would, for this bracelet's device id. Paste the three auth values from any Bee request (x-bee-proof, x-bee-secret, and your session token — an x-bee-ephemeral-token, or an Authorization Bearer token). They stay on-device.")
                    .braceletCaption()
                fetchField("API host", text: $fetchHost)
                fetchField("x-bee-proof", text: $fetchProof)
                fetchField("x-bee-secret", text: $fetchSecret)
                fetchField("session token (ephemeral or Bearer …)", text: $fetchToken)
                Button("Fetch key from Bee") {
                    bee.fetchKeyFromBeeServer(
                        host: fetchHost,
                        proof: fetchProof,
                        secret: fetchSecret,
                        sessionToken: fetchToken
                    )
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .tint(MynaTheme.cyan)
                .disabled(fetchProof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || fetchSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || fetchToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || bee.deviceID.isEmpty)
            }
            .padding(.top, 6)
        } label: {
            Text("Advanced: fetch key from Bee server").braceletLabel()
        }
        .tint(MynaTheme.ink.opacity(0.6))
    }

    /// Developer reconnaissance of the bracelet firmware: enumerate its full GATT
    /// map, test whether it will accept a null/unsigned key, and send raw control
    /// frames. All output lands in the device log below (copyable).
    @ViewBuilder
    private var labSection: some View {
        DisclosureGroup(isExpanded: $showLab) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Probes the bracelet's firmware. Results appear in the device log below — expand it and tap Copy to send them to me.")
                    .braceletCaption()
                Button("Dump full GATT map") { bee.labDumpGatt() }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tint(MynaTheme.cyan)
                Button("Probe null key (expect reject)") { bee.labProbeNullKey() }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tint(MynaTheme.gold)
                Text("Send a raw control frame (hex: id low, id high, payload…):")
                    .braceletCaption()
                HStack(spacing: 8) {
                    fetchField("e.g. 1bc0", text: $labHex)
                    Button("Send") {
                        bee.labSendControl(hex: labHex)
                        labHex = ""
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tint(MynaTheme.cyan)
                    .disabled(labHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Developer: bracelet lab").braceletLabel()
        }
        .tint(MynaTheme.ink.opacity(0.6))
    }

    private func fetchField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .lineLimit(1...3)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(MynaTheme.ink)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MynaTheme.ink.opacity(0.06)))
    }

    private var deviceLog: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(bee.diagnostics.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MynaTheme.ink.opacity(0.6))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    UIPasteboard.general.string = bee.diagnosticsText
                } label: {
                    Label("Copy log", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MynaTheme.cyan)
                .padding(.top, 4)
            }
            .padding(.top, 6)
        } label: {
            Text("Device log").braceletLabel()
        }
        .tint(MynaTheme.ink.opacity(0.6))
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(MynaTheme.ink.opacity(0.1))
            HStack {
                Text("Controls").braceletLabel()
                Spacer()
                Button { bee.refreshStatus() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MynaTheme.cyan)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Brightness").braceletCaption()
                    Spacer()
                    Text("\(Int(brightness))").braceletCaption()
                }
                Slider(value: $brightness, in: 0...255, step: 1) { editing in
                    editingBrightness = editing
                    if !editing { bee.setBrightness(Int(brightness)) }
                }
                .tint(MynaTheme.cyan)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Audio bitrate").braceletCaption()
                    Spacer()
                    Picker("", selection: Binding(
                        get: { bee.bitrate ?? bitrateOptions[2] },
                        set: { bee.setBitrate($0) }
                    )) {
                        ForEach(bitrateOptions, id: \.self) { rate in
                            Text("\(rate / 1000) kbps").tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(MynaTheme.cyan)
                }
            }

            if let txPower = bee.txPower {
                detailRow(icon: "antenna.radiowaves.left.and.right", text: "Transmit power: \(txPower)")
            }
        }
        .onChange(of: bee.brightness) { _, value in
            if let value, !editingBrightness { brightness = Double(value) }
        }
        .onAppear {
            if let value = bee.brightness { brightness = Double(value) }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text(statusText).braceletLabel()
            Spacer()
            if let battery = bee.batteryLevel {
                Label("\(battery)%", systemImage: bee.isCharging ? "battery.100.bolt" : "battery.75")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(bee.isCharging ? MynaTheme.mint : MynaTheme.ink.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private var pairingDetail: some View {
        switch bee.pairing {
        case .needsFactoryReset:
            VStack(alignment: .leading, spacing: 8) {
                Text("This bracelet is already locked to a key Myna doesn't have. To use your own key, factory-reset the bracelet — rapidly press the action button 5 times until it blinks blue and green — then tap below.")
                    .braceletCaption()
                Button("I've reset it — set my key") { bee.forgetKeyAndReprovision() }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tint(MynaTheme.cyan)
            }
        case .audioUnavailable(let reason):
            detailRow(icon: "exclamationmark.triangle.fill", text: reason, tint: MynaTheme.gold)
        case .bluetoothOff:
            detailRow(icon: "exclamationmark.triangle.fill", text: "Bluetooth is off. Turn it on to reach the bracelet.", tint: MynaTheme.gold)
        case .unauthorized:
            detailRow(icon: "exclamationmark.triangle.fill", text: "Myna needs Bluetooth permission. Enable it in Settings.", tint: MynaTheme.gold)
        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                detailRow(icon: "xmark.octagon.fill", text: message, tint: MynaTheme.magenta)
                Button("Try again") { bee.retry() }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tint(MynaTheme.cyan)
            }
        case .streaming:
            detailRow(icon: "dot.radiowaves.left.and.right", text: "Listening through the bracelet.", tint: MynaTheme.mint)
        default:
            EmptyView()
        }
    }

    private func detailRow(icon: String, text: String, tint: Color = MynaTheme.ink.opacity(0.6)) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            Text(text).braceletCaption()
        }
    }

    private var statusText: String {
        switch bee.pairing {
        case .off: return "Off"
        case .bluetoothOff: return "Bluetooth off"
        case .unauthorized: return "Needs permission"
        case .scanning: return "Looking for your bracelet…"
        case .connecting: return "Connecting…"
        case .provisioning: return "Setting up your key…"
        case .needsFactoryReset: return "Factory reset needed"
        case .streaming: return "Connected"
        case .audioUnavailable: return "Connected (audio unavailable)"
        case .error: return "Problem"
        }
    }

    private var statusColor: Color {
        switch bee.pairing {
        case .streaming: return MynaTheme.mint
        case .scanning, .connecting, .provisioning: return MynaTheme.gold
        case .error, .needsFactoryReset, .bluetoothOff, .unauthorized, .audioUnavailable: return MynaTheme.magenta
        case .off: return MynaTheme.ink.opacity(0.3)
        }
    }
}

private extension Text {
    func braceletLabel() -> Text {
        font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(MynaTheme.ink.opacity(0.9))
    }

    func braceletCaption() -> Text {
        font(.system(size: 12, design: .rounded))
            .foregroundColor(MynaTheme.ink.opacity(0.5))
    }
}
