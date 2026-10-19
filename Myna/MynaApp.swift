import SwiftData
import SwiftUI

@main
struct MynaApp: App {
    private let services = AppServices.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services.modelManager)
                .environmentObject(services.listener)
                .environmentObject(services.pilot)
                .environmentObject(services.brain)
                .environmentObject(services.contextHub)
                .environmentObject(services.bee)
                .preferredColorScheme(.dark)
        }
        .modelContainer(services.container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                services.becameActive()
            }
        }
    }
}
