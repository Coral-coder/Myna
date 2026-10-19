import SwiftUI

/// Backstage card for connecting a Bee wearable.
struct BeeCard: View {
    @EnvironmentObject private var bee: BeeBridge
    @AppStorage("myna.bee.notes") private var composeNotes = true
    @AppStorage("myna.bee.todos") private var syncTodos = true
    @State private var showTokenEntry = false
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(icon: "circle.hexagongrid.fill", title: "Bee Wearable", tint: MynaTheme.gold)

            switch bee.status {
            case .disconnected:
                disconnected
            case .pairing(let url):
                pairing(url)
            case .connected:
                connected
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(MynaTheme.magenta)
                disconnected
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.gold)
        .alert("Bee developer token", isPresented: $showTokenEntry) {
            SecureField("Token", text: $token)
            Button("Connect") {
                bee.connect(token: token)
                token = ""
            }
            Button("Cancel", role: .cancel) { token = "" }
        } message: {
            Text("Paste a token from Bee's developer tools if you'd rather not pair through bee.computer.")
        }
    }

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wear a Bee? Connect it and Myna hears what your Bee hears: say “Myna, …” to your Bee, get Myna notes for your Bee conversations, and keep to-dos in sync.")
                .settingsCaption()
            Text("First enable Developer Mode in the Bee app: Settings → tap Version five times.")
                .settingsCaption()
            HStack(spacing: 12) {
                Button {
                    bee.startPairing()
                } label: {
                    Label("Connect Bee", systemImage: "link")
                        .font(MynaTheme.display(14, weight: .semibold))
                        .foregroundStyle(MynaTheme.void)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(MynaTheme.auroraGradient))
                }
                .buttonStyle(.plain)
                Button("Use a token") { showTokenEntry = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(MynaTheme.cyan)
            }
        }
    }

    private func pairing(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().tint(MynaTheme.gold)
                Text("Approve Myna on the Bee page that just opened…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: 14) {
                Link("Open again", destination: url)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(MynaTheme.cyan)
                Button("Cancel") { bee.cancelPairing() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                GlowChip(text: bee.accountName.map { "Connected · \($0)" } ?? "Connected", icon: "checkmark.circle.fill", tint: MynaTheme.mint)
                GlowChip(text: bee.isLive ? "Live" : "Idle", icon: "dot.radiowaves.left.and.right", tint: bee.isLive ? MynaTheme.mint : .white.opacity(0.5))
            }
            if let lastSync = bee.lastSync {
                Text("Last synced \(lastSync.formatted(date: .omitted, time: .shortened))")
                    .settingsCaption()
            }
            Toggle(isOn: $composeNotes) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notes from Bee conversations").settingsLabel()
                    Text("Finished Bee conversations are composed into Myna notes by the on-device model.").settingsCaption()
                }
            }
            .tint(MynaTheme.gold)
            Toggle(isOn: $syncTodos) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync to-dos with Bee").settingsLabel()
                    Text("Your Bee's todos appear in Myna and Myna's to-dos and reminders appear on your Bee.").settingsCaption()
                }
            }
            .tint(MynaTheme.gold)
            HStack {
                Button("Sync now") { Task { await bee.refresh() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(MynaTheme.cyan)
                Spacer()
                Button("Disconnect", role: .destructive) { bee.disconnect() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
    }
}

extension Text {
    func settingsLabel() -> Text {
        font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.9))
    }

    func settingsCaption() -> Text {
        font(.system(size: 12, design: .rounded))
            .foregroundColor(.white.opacity(0.5))
    }
}
