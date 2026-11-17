import SwiftUI
import UIKit

/// The mood toggle — Daylight (neutral white) and Dusk (near-black). This is
/// Myna's own light/dark switch, independent of the host OS appearance, driving
/// every dynamic token below and the app's `preferredColorScheme`.
enum MynaMood: String, CaseIterable, Identifiable {
    case daylight
    case dusk

    var id: String { rawValue }
    var label: String { self == .daylight ? "Daylight" : "Dusk" }
    var scheme: ColorScheme { self == .dusk ? .dark : .light }
}

/// Kept only so older chrome checks (`MynaTheme.style == .grid`, etc.) still
/// compile. The three looks now resolve to the one liminal surface; the real
/// knob is `MynaMood`.
enum MynaThemeStyle: String, CaseIterable, Identifiable {
    case grid, calm, minimal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .grid: return "Grid"
        case .calm: return "Calm"
        case .minimal: return "Minimal"
        }
    }
    var blurb: String { "" }
}

/// Holds the chosen mood and republishes it so the UI re-renders on change.
/// `MynaTheme`'s dynamic colours resolve against the view's `colorScheme`, which
/// `MynaApp` drives from `mood`, so a top-level `.id(mood)` rebuild flips the
/// whole interface between Daylight and Dusk at once.
final class ThemeStore: ObservableObject {
    static let moodKey = "myna.mood"
    static let styleKey = "myna.theme"

    @Published var mood: MynaMood {
        didSet { UserDefaults.standard.set(mood.rawValue, forKey: Self.moodKey) }
    }

    /// Retained for source compatibility with screens that still read it.
    @Published var style: MynaThemeStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey) }
    }

    init() {
        mood = MynaMood(rawValue: UserDefaults.standard.string(forKey: Self.moodKey) ?? "") ?? .daylight
        style = MynaThemeStyle(rawValue: UserDefaults.standard.string(forKey: Self.styleKey) ?? "") ?? .minimal
    }
}

/// Builds a colour that resolves itself per light/dark appearance — so one token
/// serves both Daylight and Dusk.
private func dyn(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
    })
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
    static func white(_ a: CGFloat) -> UIColor { UIColor(white: 1, alpha: a) }
    static func black(_ a: CGFloat) -> UIColor { UIColor(white: 0, alpha: a) }
}

/// Myna's visual language — "a quiet operator console." One luminous neutral
/// ground, flat frosted-glass panels, hairline structure, thin type, almost no
/// icons; a single desaturated steel for the rare live signal. No colour.
///
/// The old aurora/Tron token names are kept so every screen reskins at once;
/// their values are remapped to the liminal palette (the bright accents all
/// collapse onto `ink`/`signal`, the dark canvas becomes `paper`).
enum MynaTheme {
    // MARK: Liminal palette (semantic names)

    /// The canvas. Neutral white in Daylight, near-black in Dusk.
    static let paper = dyn(UIColor(hex: 0xE7E7E4), UIColor(hex: 0x141517))
    /// A lifted ground tone for gradients and wells.
    static let paper2 = dyn(UIColor(hex: 0xF1F1EE), UIColor(hex: 0x191B1D))
    /// Primary text / foreground — near-black in Daylight, off-white in Dusk.
    static let ink = dyn(UIColor(hex: 0x1B1C1D), UIColor(hex: 0xE9E9E6))
    /// Secondary text.
    static let muted = dyn(UIColor(hex: 0x6C6D6B), UIColor(hex: 0x9B9D9E))
    /// Tertiary text — timestamps, captions.
    static let faint = dyn(UIColor(hex: 0x9B9C99), UIColor(hex: 0x6A6C6E))
    /// The one desaturated steel, for the live signal only.
    static let signal = dyn(UIColor(hex: 0x3F484C), UIColor(hex: 0xC7D0D4))

    /// Hairline structure and faint translucent fills.
    static let hair = dyn(.black(0.12), .white(0.12))
    static let hairSoft = dyn(.black(0.07), .white(0.06))
    static let veil = dyn(.white(0.55), .white(0.03))
    static let glassEdge = dyn(.white(0.70), .white(0.14))
    /// Subtle panel fill when material isn't used.
    static let glassFill = dyn(.white(0.42), .white(0.045))

    // MARK: Compatibility aliases (old names → liminal tokens)

    static let void = paper
    static let nebula = paper2
    static let indigo = signal
    static let cyan = signal
    static let magenta = signal
    static let gold = signal
    static let mint = signal
    static let panelFill = glassFill

    /// Was a cyan→magenta gradient; now a flat ink block used for headings
    /// (ink text) and primary buttons (ink fill with `void`/paper labels).
    static let auroraGradient = LinearGradient(
        colors: [ink, ink.opacity(0.86)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The listening orb — a quiet steel sweep, no rainbow.
    static let orbGradient = AngularGradient(
        colors: [signal.opacity(0.25), signal.opacity(0.75), faint.opacity(0.4), signal.opacity(0.25)],
        center: .center
    )

    /// Headings — a thin, unexpanded grotesque feel. Callers' explicit weights
    /// are honoured; the old `.width(.expanded)` is dropped for the quiet look.
    static func display(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Monospaced — timestamps, device data, the operator-console detail.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Retained for compatibility; the single liminal surface no longer branches.
    static var style: MynaThemeStyle { .minimal }
}

/// A flat frosted-glass panel: translucent material, a 1px hairline edge, no
/// shadow and no glow. Depth comes from light and blur, not elevation.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var glow: Color = MynaTheme.signal   // ignored; kept for source compatibility

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background {
            shape
                .fill(.ultraThinMaterial)
                .overlay { shape.fill(MynaTheme.veil) }
                .overlay { shape.strokeBorder(MynaTheme.hair, lineWidth: 1) }
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 14, glow: Color = MynaTheme.signal) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, glow: glow))
    }

    /// Heading / wordmark text — flat ink in the liminal language.
    func auroraText() -> some View {
        foregroundStyle(MynaTheme.ink)
    }
}

/// Section heading — a small mono eyebrow in faint ink, optional hairline icon.
/// No glow, no wide uppercase chrome.
struct SectionHeading: View {
    let icon: String
    let title: String
    var tint: Color = MynaTheme.signal

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(MynaTheme.faint)
            Text(title)
                .font(MynaTheme.mono(11))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(MynaTheme.faint)
            Spacer()
        }
    }
}

/// Small readout chip — a hairline pill with faint mono text on a veil.
struct GlowChip: View {
    let text: String
    var icon: String?
    var tint: Color = MynaTheme.signal

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .regular))
            }
            Text(text)
                .font(MynaTheme.mono(11))
                .tracking(0.5)
        }
        .foregroundStyle(MynaTheme.muted)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(MynaTheme.veil))
        .overlay(Capsule().strokeBorder(MynaTheme.hair, lineWidth: 1))
    }
}
