import SwiftUI

/// The stage. Three places plus Settings, stacked top to bottom with nothing
/// floating over anything else: an optional notice line, the active screen, and
/// a plain text tab bar.
struct RootView: View {
    enum Tab: String, CaseIterable {
        case ask = "Ask"
        case today = "Today"
        case memory = "Memory"
        case settings = "Settings"
    }

    @State private var tab: Tab = .ask
    @EnvironmentObject private var pilot: ConversationPilot
    @EnvironmentObject private var themeStore: ThemeStore
    @AppStorage("myna.onboarded") private var onboarded = false

    var body: some View {
        Group {
            if themeStore.look == .vfd {
                VFDRootView()
            } else {
                standard
            }
        }
        .fullScreenCover(isPresented: .constant(!onboarded)) {
            PermissionsView(onboarded: $onboarded)
        }
        .onChange(of: onboarded) { _, isOnboarded in
            if isOnboarded { AppServices.shared.becameActive() }
        }
    }

    private var standard: some View {
        VStack(spacing: 0) {
            notice

            Group {
                switch tab {
                case .ask: ChatView()
                case .today: TodayView()
                case .memory: MemoryHubView()
                case .settings: SettingsMenuView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Rebuild the active screen when the mood flips so every card and
            // heading resolves its Daylight / Dusk tones.
            .id(themeStore.mood)

            tabBar
        }
        .background { AuroraBackground(energy: pilot.phase == .listening ? 0.9 : 0.35) }
    }

    // MARK: - Tab bar (a row of its own, below the content)

    private var tabBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(MynaTheme.hair).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        Text(item.rawValue)
                            .font(MynaTheme.mono(12))
                            .tracking(1.4)
                            .textCase(.uppercase)
                            .foregroundStyle(tab == item ? MynaTheme.ink : MynaTheme.faint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(MynaTheme.paper)
    }

    // MARK: - Notice (a row of its own, above the content)

    @ViewBuilder
    private var notice: some View {
        if let banner = pilot.banner {
            VStack(spacing: 0) {
                Text(banner)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(MynaTheme.ink)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                Rectangle().fill(MynaTheme.hair).frame(height: 1)
            }
            .background(MynaTheme.paper2)
            .task {
                try? await Task.sleep(for: .seconds(5))
                pilot.banner = nil
            }
        }
    }
}

#Preview {
    let services = AppServices.shared
    RootView()
        .environmentObject(ThemeStore())
        .environmentObject(services.modelManager)
        .environmentObject(services.listener)
        .environmentObject(services.pilot)
        .environmentObject(services.brain)
        .environmentObject(services.contextHub)
        .environmentObject(services.bee)
        .environmentObject(services.beeCloud)
        .modelContainer(services.container)
}
