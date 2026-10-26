import SwiftUI

/// Backstage card: a live look at the transcription pipeline, so you can see
/// exactly what's reaching the recognizer — from the bracelet or the mic — and
/// whether it's turning into text. Updates in real time.
struct LiveDebugCard: View {
    @EnvironmentObject private var listener: SpeechListener
    @EnvironmentObject private var pilot: ConversationPilot
    @EnvironmentObject private var bee: BeeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(icon: "waveform.badge.magnifyingglass", title: "Live transcription (debug)", tint: MynaTheme.mint)

            row("Source", source)
            row("Recognizer", listener.recognizerStatus)
            row("Pilot", String(describing: pilot.phase))
            if bee.isEnabled {
                row("Bracelet", braceletLine)
                row("Audio packets", "\(bee.packetsDecoded)\(bee.audioActive ? " · flowing" : "")")
            }
            row("Recognition ticks", "\(listener.recognitionTicks)")
            row("Composed today", "\(pilot.notesComposedToday)")

            // Live mic/stream level.
            VStack(alignment: .leading, spacing: 4) {
                Text("Level").debugKey()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(MynaTheme.mint)
                            .frame(width: max(2, geo.size.width * CGFloat(min(1, listener.audioLevel))))
                    }
                }
                .frame(height: 6)
                .animation(.easeOut(duration: 0.15), value: listener.audioLevel)
            }
            .padding(.vertical, 2)

            // Live partial + recent finals.
            VStack(alignment: .leading, spacing: 6) {
                Text("Heard").debugKey()
                ForEach(pilot.liveTranscriptTail) { line in
                    Text(line.text)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !listener.liveTranscript.isEmpty {
                    Text(listener.liveTranscript)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(MynaTheme.mint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if pilot.liveTranscriptTail.isEmpty && listener.liveTranscript.isEmpty {
                    Text(bee.audioActive ? "Audio is flowing but no words yet — check Recognizer above." : "Nothing yet.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .italic()
                }
            }

            if let err = listener.lastError {
                Text(err)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(MynaTheme.gold)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(glow: MynaTheme.mint)
    }

    private var source: String {
        if listener.usingExternalSource { return "Bee bracelet" }
        if listener.isListening { return "iPhone mic" }
        return "none"
    }

    private var braceletLine: String {
        switch bee.pairing {
        case .streaming: return "streaming" + (bee.codec.map { " · \($0.description)" } ?? "")
        case .audioUnavailable(let r): return "audio unavailable — \(r)"
        case .needsFactoryReset: return "needs factory reset / key"
        case .error(let m): return "error — \(m)"
        default: return String(describing: bee.pairing)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key).debugKey().frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private extension Text {
    func debugKey() -> some View {
        self.font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
    }
}
