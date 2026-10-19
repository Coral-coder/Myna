import SwiftUI

/// The stage: aurora backdrop, the active scene, and a floating glass dock.
struct RootView: View {
    enum Tab: String, CaseIterable {
        case listen = "Listen"
        case notes = "Notes"
        case lists = "Lists"
        case models = "Neural Core"
        case settings = "Backstage"

        var icon: String {
            switch self {
            case .listen: return "waveform"
            case .notes: return "sparkles.rectangle.stack"
            case .lists: return "checklist"
            case .models: return "cpu"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    @State private var tab: Tab = .listen
    @EnvironmentObject private var pilot: ConversationPilot
    @AppStorage("myna.onboarded") private var onboarded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            AuroraBackground(energy: pilot.phase == .listening ? 0.9 : 0.35)

            Group {
                switch tab {
                case .listen: DashboardView()
                case .notes: NotesListView()
                case .lists: ListsView()
                case .models: ModelHubView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaPadding(.bottom, 84)

            dock
        }
        .overlay(alignment: .top) { bannerView }
        .fullScreenCover(isPresented: .constant(!onboarded)) {
            PermissionsView(onboarded: $onboarded)
        }
        .onChange(of: onboarded) { _, isOnboarded in
            if isOnboarded { AppServices.shared.becameActive() }
        }
    }

    private var dock: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    withAnimation(.bouncy(duration: 0.35)) { tab = item }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 19, weight: .semibold))
                            .symbolEffect(.bounce, value: tab == item)
                        Text(item.rawValue)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .tracking(0.5)
                    }
                    .foregroundStyle(tab == item ? AnyShapeStyle(MynaTheme.auroraGradient) : AnyShapeStyle(.white.opacity(0.45)))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.white.opacity(0.07))
                                .padding(4)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard(cornerRadius: 26)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner = pilot.banner {
            Text(banner)
                .font(MynaTheme.display(13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassCard(cornerRadius: 16, glow: MynaTheme.gold)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { pilot.banner = nil }
                }
        }
    }
}

#Preview {
    let services = AppServices.shared
    RootView()
        .environmentObject(services.modelManager)
        .environmentObject(services.listener)
        .environmentObject(services.pilot)
        .environmentObject(services.brain)
        .environmentObject(services.bee)
        .modelContainer(services.container)
}
