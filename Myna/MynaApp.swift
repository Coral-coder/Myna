import SwiftData
import SwiftUI

@main
struct MynaApp: App {
    private let services = AppServices.shared
    @StateObject private var themeStore = ThemeStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(themeStore)
                .environmentObject(services.modelManager)
                .environmentObject(services.listener)
                .environmentObject(services.pilot)
                .environmentObject(services.brain)
                .environmentObject(services.contextHub)
                .environmentObject(services.bee)
                .environmentObject(services.beeCloud)
                .environmentObject(services.whisper)
                .environmentObject(services.neuralVoice)
                .preferredColorScheme(themeStore.mood.scheme)
                .onOpenURL { url in
                    // The pairing QR the home server shows opens Myna with this link.
                    if url.scheme == "myna", url.host == "pair" { HomeServer.shared.pair(link: url.absoluteString) }
                }
        }
        .modelContainer(services.container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                services.becameActive()
            case .inactive:
                services.modelManager.stopGenerationForBackground()
            case .background:
                services.modelManager.stopGenerationForBackground()
                services.enteredBackground()
            default:
                break
            }
        }
    }
}
