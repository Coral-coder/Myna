import SwiftUI

/// The three selectable looks. They share one palette and layout; what changes
/// is the *chrome* — background, card edges, and heading treatment — from the
/// full neon Grid down to a flat, quiet minimal.
enum MynaThemeStyle: String, CaseIterable, Identifiable {
    case grid       // the original Tron Grid: animated grid, glowing cards
    case calm       // same identity, glows and uppercase stripped, flat cards
    case minimal    // near-flat, quiet, almost no chrome

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grid: return "Grid"
        case .calm: return "Calm"
        case .minimal: return "Minimal"
        }
    }

    var blurb: String {
        switch self {
        case .grid: return "The original — animated grid, glowing panels, wide uppercase labels."
        case .calm: return "Same look, dialled down: no glow, flat panels, normal headings."
        case .minimal: return "Quiet and flat. Almost no chrome — just your content."
        }
    }
}

/// Holds the chosen look and republishes it so the UI re-renders on change.
/// `MynaTheme` reads `ThemeStore.currentStyle` (a plain static) from inside its
/// chrome, so a top-level `.id(style)` rebuild picks up the new look everywhere.
final class ThemeStore: ObservableObject {
    static let key = "myna.theme"
    static private(set) var currentStyle: MynaThemeStyle =
        MynaThemeStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .grid

    @Published var style: MynaThemeStyle {
        didSet {
            ThemeStore.currentStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: Self.key)
        }
    }

    init() { style = ThemeStore.currentStyle }
}

/// Myna's visual language — "Tron Legacy meets future tech": a near-black grid,
/// electric-cyan light, a single amber accent, sharp panels edged in glowing
/// hairlines, and wide, high-contrast type. Restrained and businesslike.
///
/// The token names are kept from the old aurora theme so every screen reskins
/// at once; their values are remapped to the Tron palette (e.g. `magenta` is now
/// the secondary electric blue, `gold` the amber accent).
enum MynaTheme {
    /// The canvas: black with a faint blue cast.
    static let void = Color(red: 0.016, green: 0.027, blue: 0.043)
    /// Panel and grid blues.
    static let nebula = Color(red: 0.04, green: 0.07, blue: 0.11)
    static let indigo = Color(red: 0.10, green: 0.18, blue: 0.30)
    /// Primary light — electric cyan.
    static let cyan = Color(red: 0.33, green: 0.82, blue: 0.98)
    /// Secondary — electric blue (was magenta).
    static let magenta = Color(red: 0.30, green: 0.56, blue: 1.0)
    /// The one warm accent — amber (the Grid's adversary colour).
    static let gold = Color(red: 1.0, green: 0.68, blue: 0.24)
    /// Positive / live — cyan-teal.
    static let mint = Color(red: 0.36, green: 0.96, blue: 0.82)

    /// Dark glassy fill for panels.
    static let panelFill = Color(red: 0.03, green: 0.05, blue: 0.08)

    /// Two-tone cyan→blue — deliberately not a rainbow, to read professional.
    static let auroraGradient = LinearGradient(
        colors: [cyan, magenta],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let orbGradient = AngularGradient(
        colors: [cyan, magenta, cyan, gold, cyan],
        center: .center
    )

    /// Wide, expanded type — the Tron "Eurostile" feel, clean enough for business.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default).width(.expanded)
    }

    /// Monospaced, for data and readouts.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The currently selected look. Chrome (cards, headings, background) reads
    /// this to decide how loud to be.
    static var style: MynaThemeStyle { ThemeStore.currentStyle }
}

/// A sharp "circuit panel": dark glass, a glowing hairline edge, a faint outer
/// bloom. Replaces the old frosted card.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 12
    var glow: Color = MynaTheme.cyan

    func body(content: Content) -> some View {
        content.background { cardBackground }
    }

    @ViewBuilder private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch MynaTheme.style {
        case .grid:
            shape
                .fill(.ultraThinMaterial)
                .overlay { shape.fill(MynaTheme.panelFill.opacity(0.55)) }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [glow.opacity(0.7), glow.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: glow.opacity(0.22), radius: 12, y: 0)
        case .calm:
            shape
                .fill(MynaTheme.panelFill.opacity(0.72))
                .overlay { shape.strokeBorder(glow.opacity(0.22), lineWidth: 1) }
        case .minimal:
            shape
                .fill(.white.opacity(0.05))
                .overlay { shape.strokeBorder(.white.opacity(0.09), lineWidth: 1) }
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 12, glow: Color = MynaTheme.cyan) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, glow: glow))
    }

    /// Gradient-tinted text used for headings and the wordmark.
    func auroraText() -> some View {
        foregroundStyle(MynaTheme.auroraGradient)
    }
}

/// Section heading — an SF Symbol node plus a wide, tracked, uppercase label.
struct SectionHeading: View {
    let icon: String
    let title: String
    var tint: Color = MynaTheme.cyan

    var body: some View {
        let style = MynaTheme.style
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(style == .minimal ? .white.opacity(0.6) : tint)
                .shadow(color: style == .grid ? tint.opacity(0.8) : .clear, radius: style == .grid ? 6 : 0)
            Text(title)
                .font(style == .grid ? MynaTheme.display(14, weight: .semibold)
                                     : .system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(style == .minimal ? 0.8 : 0.92))
                .tracking(style == .grid ? 3 : 0)
                .textCase(style == .grid ? .uppercase : nil)
            Spacer()
        }
    }
}

/// Small glowing readout chip — a sharp rectangle edged in light.
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
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.5)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }
}
