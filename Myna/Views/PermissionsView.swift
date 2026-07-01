import SwiftUI

/// Opening night: a guided tour through the three permissions Myna needs,
/// shown once on first launch.
struct PermissionsView: View {
    @Binding var onboarded: Bool
    @EnvironmentObject private var pilot: ConversationPilot
    @State private var micGranted = false
    @State private var calendarGranted = false
    @State private var requesting = false

    var body: some View {
        ZStack {
            AuroraBackground(energy: 0.7)

            VStack(spacing: 26) {
                Spacer()

                ListeningOrb(isListening: false, isComposing: false, level: 0)
                    .scaleEffect(0.72)
                    .frame(height: 170)

                VStack(spacing: 8) {
                    Text("Welcome to MYNA")
                        .font(MynaTheme.display(28, weight: .heavy))
                        .auroraText()
                    Text("A listener that turns your day's conversations\ninto beautiful notes — entirely on this iPhone.")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    permissionRow(
                        icon: "mic.fill",
                        tint: MynaTheme.cyan,
                        title: "Microphone",
                        detail: "Hear the room and transcribe it with on-device Whisper.",
                        granted: micGranted
                    )
                    permissionRow(
                        icon: "calendar",
                        tint: MynaTheme.magenta,
                        title: "Calendar",
                        detail: "Schedule the meetings you agree to out loud.",
                        granted: calendarGranted
                    )
                    permissionRow(
                        icon: "lock.shield.fill",
                        tint: MynaTheme.mint,
                        title: "No Cloud. Ever.",
                        detail: "Audio, transcripts and notes never leave the device.",
                        granted: true
                    )
                }
                .padding(.horizontal, 24)

                Spacer()

                Button(action: begin) {
                    HStack {
                        if requesting { ProgressView().tint(MynaTheme.void) }
                        Text(micGranted ? "Enter Myna" : "Begin the Experience")
                            .font(MynaTheme.display(16, weight: .bold))
                    }
                    .foregroundStyle(MynaTheme.void)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(MynaTheme.auroraGradient))
                    .shadow(color: MynaTheme.magenta.opacity(0.6), radius: 16, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(requesting)
                .padding(.horizontal, 32)
                .padding(.bottom, 36)
            }
        }
    }

    private func permissionRow(icon: String, tint: Color, title: String, detail: String, granted: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(granted ? MynaTheme.mint : .white.opacity(0.3))
        }
        .padding(14)
        .glassCard(cornerRadius: 18, glow: tint)
    }

    private func begin() {
        requesting = true
        Task { @MainActor in
            micGranted = await AudioCaptureEngine.requestMicrophonePermission()
            calendarGranted = await pilot.scheduler.requestAccess()
            requesting = false
            // Calendar is optional; the microphone is the heart of the app.
            if micGranted {
                onboarded = true
            }
        }
    }
}
