import SwiftUI

/// The heart of the show: a living, breathing orb that pulses with the room's
/// sound while Myna listens, and spins a slow constellation while idle.
struct ListeningOrb: View {
    var isListening: Bool
    var isComposing: Bool
    /// Microphone energy 0...1.
    var level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = isListening ? 1.0 + 0.10 * level + 0.02 * sin(t * 3) : 1.0 + 0.015 * sin(t * 1.4)

            ZStack {
                // Outer halo — a soft rotating aurora ring.
                Circle()
                    .strokeBorder(MynaTheme.orbGradient, lineWidth: 10)
                    .blur(radius: 18)
                    .opacity(isListening ? 0.85 : 0.35)
                    .rotationEffect(.radians(t * (isComposing ? 1.6 : 0.25)))
                    .scaleEffect(pulse * 1.06)

                // Ripples that bloom outward with the voice.
                if isListening {
                    ForEach(0..<3, id: \.self) { ring in
                        let phase = (t * 0.5 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(MynaTheme.cyan.opacity((1 - phase) * 0.4 * (0.4 + level)), lineWidth: 1.5)
                            .scaleEffect(1 + phase * 0.55)
                    }
                }

                // Glassy body.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                MynaTheme.indigo.opacity(0.95),
                                MynaTheme.nebula.opacity(0.9),
                                MynaTheme.void,
                            ],
                            center: .init(x: 0.35, y: 0.3),
                            startRadius: 10,
                            endRadius: 150
                        )
                    )
                    .overlay {
                        Circle().strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.5), MynaTheme.cyan.opacity(0.2), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                    }
                    .scaleEffect(pulse)
                    .shadow(color: MynaTheme.cyan.opacity(isListening ? 0.5 : 0.2), radius: 40)

                // Inner waveform constellation.
                WaveformRing(time: t, level: isListening ? level : 0.06)
                    .scaleEffect(pulse)

                // Center glyph.
                Image(systemName: isComposing ? "sparkles" : (isListening ? "waveform" : "moon.stars.fill"))
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(MynaTheme.auroraGradient)
                    .symbolEffect(.variableColor.iterative, isActive: isListening || isComposing)
                    .shadow(color: MynaTheme.magenta.opacity(0.7), radius: 12)
            }
        }
        .frame(width: 230, height: 230)
        .accessibilityLabel(isListening ? "Listening" : "Not listening")
    }
}

/// A ring of luminous bars dancing to the microphone level.
private struct WaveformRing: View {
    let time: TimeInterval
    let level: Double

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = min(size.width, size.height) * 0.30
            let bars = 48
            for i in 0..<bars {
                let angle = Double(i) / Double(bars) * 2 * .pi
                let wobble = sin(time * 4 + Double(i) * 0.9) * 0.5 + 0.5
                let length = 4 + (10 + 26 * level) * wobble
                let inner = CGPoint(
                    x: center.x + cos(angle) * baseRadius,
                    y: center.y + sin(angle) * baseRadius
                )
                let outer = CGPoint(
                    x: center.x + cos(angle) * (baseRadius + length),
                    y: center.y + sin(angle) * (baseRadius + length)
                )
                var path = Path()
                path.move(to: inner)
                path.addLine(to: outer)
                let hueShift = (Double(i) / Double(bars) + time * 0.05).truncatingRemainder(dividingBy: 1)
                let color = Color(hue: 0.5 + 0.35 * hueShift, saturation: 0.75, brightness: 1.0)
                context.stroke(path, with: .color(color.opacity(0.35 + 0.55 * level)), style: .init(lineWidth: 2, lineCap: .round))
            }
        }
    }
}

#Preview {
    ZStack {
        AuroraBackground(energy: 0.8)
        ListeningOrb(isListening: true, isComposing: false, level: 0.6)
    }
}
