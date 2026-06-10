import SwiftUI

/// Myna's visual language: deep-space indigo, aurora cyan, magenta and "pixie dust" gold.
enum MynaTheme {
    static let void = Color(red: 0.02, green: 0.024, blue: 0.06)
    static let nebula = Color(red: 0.07, green: 0.05, blue: 0.18)
    static let indigo = Color(red: 0.16, green: 0.10, blue: 0.38)
    static let cyan = Color(red: 0.22, green: 0.90, blue: 1.0)
    static let magenta = Color(red: 1.0, green: 0.31, blue: 0.85)
    static let gold = Color(red: 1.0, green: 0.78, blue: 0.34)
    static let mint = Color(red: 0.45, green: 1.0, blue: 0.78)

    static let auroraGradient = LinearGradient(
        colors: [cyan, magenta, gold],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let orbGradient = AngularGradient(
        colors: [cyan, magenta, gold, mint, cyan],
        center: .center
    )

    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Frosted "show control" panel used throughout the app.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 24
    var glow: Color = MynaTheme.cyan

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [glow.opacity(0.55), .white.opacity(0.08), MynaTheme.magenta.opacity(0.35)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: glow.opacity(0.18), radius: 18, y: 8)
            }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24, glow: Color = MynaTheme.cyan) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, glow: glow))
    }

    /// Gradient-tinted text used for headings and the wordmark.
    func auroraText() -> some View {
        foregroundStyle(MynaTheme.auroraGradient)
    }
}

/// Section heading with an SF Symbol "marquee light".
struct SectionHeading: View {
    let icon: String
    let title: String
    var tint: Color = MynaTheme.cyan

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .shadow(color: tint.opacity(0.8), radius: 6)
            Text(title)
                .font(MynaTheme.display(15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .tracking(2.5)
                .textCase(.uppercase)
            Spacer()
        }
    }
}

/// Small glowing capsule chip ("E-ticket" badge).
struct GlowChip: View {
    let text: String
    var icon: String?
    var tint: Color = MynaTheme.cyan

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
    }
}
