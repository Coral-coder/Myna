import SwiftUI

/// Everything that doesn't need to live in the dock: the Bee inbox, the model
/// hub and settings. Tucked behind one "More" tab so the main surfaces stay calm.
struct MoreView: View {
    private enum Destination: String, CaseIterable, Identifiable {
        case inbox, models, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .inbox: return "Inbox"
            case .models: return "Neural Core"
            case .settings: return "Settings"
            }
        }
        var subtitle: String {
            switch self {
            case .inbox: return "Suggestions from your Bee conversations, waiting for a tap"
            case .models: return "Download and pick the on-device model Myna runs"
            case .settings: return "Listening, voice, Bee, diagnostics"
            }
        }
        var icon: String {
            switch self {
            case .inbox: return "tray.full"
            case .models: return "cpu"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    SectionHeading(icon: "ellipsis.circle", title: "More", tint: MynaTheme.cyan)
                        .padding(.top, 12)
                    ForEach(Destination.allCases) { item in
                        NavigationLink(value: item) {
                            row(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .navigationDestination(for: Destination.self) { item in
                switch item {
                case .inbox: SuggestionsView()
                case .models: ModelHubView()
                case .settings: SettingsView()
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .background(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func row(_ item: Destination) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(MynaTheme.style == .minimal ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(MynaTheme.auroraGradient))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(MynaTheme.display(16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(item.subtitle)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }
}
