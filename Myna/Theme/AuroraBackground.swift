import SwiftUI

/// The liminal ground: a calm neutral field with a faint luminous lift at the
/// top and bottom — the quiet operator-console backdrop. Flat in both moods;
/// depth comes from light, not chrome. A barely-there steel breath rises when
/// Myna is listening. (Name kept so every screen keeps using it.)
struct AuroraBackground: View {
    /// Lifts the faint listening breath when Myna is actively listening.
    var energy: Double = 0.35

    var body: some View {
        ZStack {
            MynaTheme.paper.ignoresSafeArea()

            // Soft luminous lifts, top and bottom — the concept's radial ground.
            LinearGradient(
                colors: [MynaTheme.paper2.opacity(0.9), .clear, MynaTheme.paper2.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            RadialGradient(
                colors: [MynaTheme.veil, .clear],
                center: .top, startRadius: 0, endRadius: 520
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // The rare live signal — a faint steel wash while listening.
            if energy > 0.5 {
                RadialGradient(
                    colors: [MynaTheme.signal.opacity(0.06 * energy), .clear],
                    center: .center, startRadius: 40, endRadius: 440
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

#Preview {
    AuroraBackground(energy: 0.8)
}
