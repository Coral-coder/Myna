import SwiftUI

/// The Grid: a dark field ruled with thin cyan lines, a slow scanline sweeping
/// down it, and a few drifting data motes. Brightens when Myna is listening.
/// (Name kept from the old aurora background so every screen keeps using it.)
struct AuroraBackground: View {
    /// Ramps the Grid up when Myna is actively listening.
    var energy: Double = 0.35

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                MynaTheme.void.ignoresSafeArea()

                GridField(time: t, energy: energy)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Vignette: pull the eye to the centre, darken the edges.
                RadialGradient(
                    colors: [.clear, MynaTheme.void.opacity(0.85)],
                    center: .center,
                    startRadius: 140,
                    endRadius: 560
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
    }
}

/// Cheap, state-free Grid drawn with Canvas: ruled lines, a glowing horizontal
/// scanline, and drifting motes.
private struct GridField: View {
    let time: TimeInterval
    let energy: Double

    private let spacing: CGFloat = 46

    var body: some View {
        Canvas { context, size in
            let base = 0.05 + 0.06 * energy
            let lineColor = MynaTheme.cyan.opacity(base)

            // Ruled grid.
            var grid = Path()
            var x: CGFloat = 0
            while x <= size.width {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(grid, with: .color(lineColor), lineWidth: 0.75)

            // Scanline sweeping down, with a soft glow band behind it.
            let scanY = CGFloat(fract(time * 0.05)) * size.height
            let band = CGRect(x: 0, y: scanY - 36, width: size.width, height: 72)
            context.fill(
                Rectangle().path(in: band),
                with: .linearGradient(
                    Gradient(colors: [.clear, MynaTheme.cyan.opacity(0.10 + 0.12 * energy), .clear]),
                    startPoint: CGPoint(x: 0, y: band.minY),
                    endPoint: CGPoint(x: 0, y: band.maxY)
                )
            )
            var scan = Path()
            scan.move(to: CGPoint(x: 0, y: scanY))
            scan.addLine(to: CGPoint(x: size.width, y: scanY))
            context.stroke(scan, with: .color(MynaTheme.cyan.opacity(0.35 + 0.3 * energy)), lineWidth: 1)

            // Drifting data motes along grid columns.
            for i in 0..<18 {
                let seed = Double(i)
                let col = (Double(i) * 2 + 1)
                let mx = CGFloat(col) * spacing
                guard mx <= size.width else { continue }
                let speed = 0.03 + 0.05 * fract(seed * 0.613)
                let my = CGFloat(fract(seed * 0.271 + time * speed)) * size.height
                let glow = 0.25 + 0.55 * (0.5 + 0.5 * sin(time * 1.4 + seed))
                let color = (i % 7 == 0 ? MynaTheme.gold : MynaTheme.cyan).opacity(glow * (0.5 + energy))
                let dot = CGRect(x: mx - 1.5, y: my - 1.5, width: 3, height: 3)
                context.fill(Rectangle().path(in: dot), with: .color(color))
            }
        }
    }

    private func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}

#Preview {
    AuroraBackground(energy: 0.8)
}
