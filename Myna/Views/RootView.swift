import SwiftUI

/// Reports the floating dock's real rendered height so content can clear it.
private struct DockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The stage: liminal ground, the active scene, a text-only dock, and the
/// Daylight / Dusk mood toggle. Four words, no icons.
struct RootView: View {
    /// The four places from the concept. Everything the app does lives under one
    /// of these; the secondary day-outputs hang off Today.
    enum Tab: String, CaseIterable {
        case ask = "Ask"
        case today = "Today"
        case memory = "Memory"
        case backstage = "Backstage"
    }

    /// Today's secondary destinations, kept reachable without extra chrome.
    enum TodaySub: String, CaseIterable {
        case today = "Today"
        case notes = "Notes"
        case lists = "Lists"
        case inbox = "Inbox"
        case core = "Core"
    }

    @State private var tab: Tab = .ask
    @State private var todaySub: TodaySub = .today
    @EnvironmentObject private var pilot: ConversationPilot
    @EnvironmentObject private var themeStore: ThemeStore
    @AppStorage("myna.onboarded") private var onboarded = false
    @State private var dockClearance: CGFloat = 100

    var body: some View {
        ZStack(alignment: .bottom) {
            AuroraBackground(energy: pilot.phase == .listening ? 0.9 : 0.35)

            Group {
                switch tab {
                case .ask: ChatView()
                case .today: todayStage
                case .memory: MemoriesView()
                case .backstage: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaPadding(.bottom, dockClearance)
            // Rebuild the active screen when the mood flips so every card and
            // heading resolves its Daylight / Dusk tones.
            .id(themeStore.mood)

            dock
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: DockHeightKey.self, value: geo.size.height + 12)
                    }
                )
        }
        .onPreferenceChange(DockHeightKey.self) { dockClearance = $0 }
        .overlay(alignment: .topTrailing) { moodToggle }
        .overlay(alignment: .top) { bannerView }
        .fullScreenCover(isPresented: .constant(!onboarded)) {
            PermissionsView(onboarded: $onboarded)
        }
        .onChange(of: onboarded) { _, isOnboarded in
            if isOnboarded { AppServices.shared.becameActive() }
        }
    }

    // MARK: - Today, with its quiet overflow nav

    private var todayStage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(TodaySub.allCases, id: \.self) { sub in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { todaySub = sub }
                    } label: {
                        Text(sub.rawValue)
                            .font(MynaTheme.mono(11))
                            .tracking(1.5)
                            .textCase(.uppercase)
                            .foregroundStyle(todaySub == sub ? MynaTheme.ink : MynaTheme.faint)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(MynaTheme.hairSoft).frame(height: 1)
            }

            Group {
                switch todaySub {
                case .today: DashboardView()
                case .notes: NotesListView()
                case .lists: ListsView()
                case .inbox: SuggestionsView()
                case .core: ModelHubView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Dock (text nav, no icons)

    private var dock: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { tab = item }
                } label: {
                    Text(item.rawValue)
                        .font(MynaTheme.mono(11))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(tab == item ? MynaTheme.ink : MynaTheme.faint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(MynaTheme.veil)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(MynaTheme.hair, lineWidth: 1)
                }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    // MARK: - Mood toggle (Daylight / Dusk)

    private var moodToggle: some View {
        HStack(spacing: 2) {
            ForEach(MynaMood.allCases) { mood in
                Button {
                    withAnimation(.easeInOut(duration: 0.4)) { themeStore.mood = mood }
                } label: {
                    Text(mood.label)
                        .font(MynaTheme.mono(9.5))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(themeStore.mood == mood ? MynaTheme.ink : MynaTheme.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            if themeStore.mood == mood {
                                Capsule().fill(MynaTheme.veil)
                                    .overlay(Capsule().strokeBorder(MynaTheme.glassEdge, lineWidth: 1))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(MynaTheme.hair, lineWidth: 1))
        .padding(.trailing, 18)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var bannerView: some View {
        if let banner = pilot.banner {
            Text(banner)
                .font(MynaTheme.display(13, weight: .regular))
                .foregroundStyle(MynaTheme.ink)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassCard(cornerRadius: 16)
                .padding(.horizontal, 24)
                .padding(.top, 54)
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
