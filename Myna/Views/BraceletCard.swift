import SwiftUI

/// Backstage card: pair and watch the Bee bracelet — your own device, your own
/// key. Shows connection state, battery, firmware and the audio codec, and
/// explains the one manual step (a factory reset) for a bracelet that's sealed
/// with a key Myna doesn't hold.
struct BraceletCard: View {
    @EnvironmentObject private var bee: BeeManager

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
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.cyan)
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
            detailRow(icon: "xmark.octagon.fill", text: message, tint: MynaTheme.magenta)
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
