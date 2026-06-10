import SwiftUI

/// Slow-breathing aurora mesh with drifting "pixie dust" — the stage lighting behind every screen.
struct AuroraBackground: View {
    /// Ramps the aurora up when Myna is actively listening.
    var energy: Double = 0.35

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                MynaTheme.void.ignoresSafeArea()

                MeshGradient(
                    width: 3,
                    height: 3,
                    points: meshPoints(t: t),
                    colors: meshColors
                )
                .opacity(0.55 + 0.3 * energy)
                .blur(radius: 40)
                .ignoresSafeArea()

                StardustField(time: t, energy: energy)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }

    private var meshColors: [Color] {
        [
            MynaTheme.void, MynaTheme.nebula, MynaTheme.void,
            MynaTheme.indigo, MynaTheme.magenta.opacity(0.45), MynaTheme.cyan.opacity(0.35),
            MynaTheme.void, MynaTheme.indigo, MynaTheme.void,
        ]
    }

    private func meshPoints(t: TimeInterval) -> [SIMD2<Float>] {
        let s = Float(sin(t * 0.18)) * 0.12
        let c = Float(cos(t * 0.13)) * 0.12
        return [
            [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
            [0.0, 0.5 + s], [0.5 + c, 0.5 - s], [1.0, 0.5 + c],
            [0.0, 1.0], [0.5, 1.0], [1.0, 1.0],
        ]
    }
}

/// Deterministic floating sparkle particles drawn with Canvas (cheap, no state).
private struct StardustField: View {
    let time: TimeInterval
    let energy: Double

    var body: some View {
        Canvas { context, size in
            for i in 0..<46 {
                let seed = Double(i)
                let speed = 0.012 + 0.02 * fract(seed * 0.717)
                let x = fract(seed * 0.371 + time * speed * 0.3) * size.width
                let y = fract(seed * 0.613 - time * speed) * size.height
                let twinkle = 0.5 + 0.5 * sin(time * (1.2 + fract(seed * 0.911) * 2) + seed)
                let radius = 0.8 + 1.8 * fract(seed * 0.527)
                let alpha = (0.12 + 0.5 * twinkle) * (0.5 + energy)

                let colors: [Color] = [MynaTheme.cyan, MynaTheme.gold, MynaTheme.magenta, .white]
                let color = colors[i % colors.count].opacity(alpha)
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Ellipse().path(in: rect), with: .color(color))
            }
        }
    }

    private func fract(_ value: Double) -> Double {
        value - value.rounded(.down)
    }
}

#Preview {
    AuroraBackground(energy: 0.8)
}
