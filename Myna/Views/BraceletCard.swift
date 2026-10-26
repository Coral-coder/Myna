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
                if bee.isReadyForControl, bee.deviceState == .mute {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow(icon: "mic.slash.fill", text: "The bracelet is muted, so it isn't sending audio.", tint: MynaTheme.gold)
                        Button("Unmute bracelet") { bee.setRecording(true) }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .tint(MynaTheme.cyan)
                    }
                }
                if bee.isReadyForControl { controlsSection }
                if !bee.diagnostics.isEmpty { deviceLog }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.cyan)
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
                        .foregroundStyle(.white.opacity(0.75))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy key") { UIPasteboard.general.string = keyHex }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .tint(MynaTheme.cyan)
                    Divider().overlay(.white.opacity(0.1))
                }
                Text("Paste the bytes from the bracelet's SetEncryptionKey write (the value after 18 C0, 108 bytes as hex). Myna stores it on-device and uses it to decrypt audio — no Bee server.")
                    .braceletCaption()
                TextField("18c0… or the 108-byte hex", text: $pastedKey, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06)))
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
        .tint(.white.opacity(0.6))
    }

    private var deviceLog: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(bee.diagnostics.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
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
        .tint(.white.opacity(0.6))
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(.white.opacity(0.1))
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
                    .foregroundStyle(bee.isCharging ? MynaTheme.mint : .white.opacity(0.7))
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

    private func detailRow(icon: String, text: String, tint: Color = .white.opacity(0.6)) -> some View {
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
        case .off: return .white.opacity(0.3)
        }
    }
}

private extension Text {
    func braceletLabel() -> Text {
        font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.9))
    }

    func braceletCaption() -> Text {
        font(.system(size: 12, design: .rounded))
            .foregroundColor(.white.opacity(0.5))
    }
}
