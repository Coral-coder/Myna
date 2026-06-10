import SwiftData
import SwiftUI

@main
struct MynaApp: App {
    private let sharedModelContainer: ModelContainer
    @StateObject private var modelManager: ModelManager
    @StateObject private var listener: SpeechListener
    @StateObject private var pilot: ConversationPilot

    init() {
        do {
            sharedModelContainer = try ModelContainer(for: ConversationNote.self)
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }

        let manager = ModelManager()
        let speechListener = SpeechListener()
        let conversationPilot = ConversationPilot(listener: speechListener, modelManager: manager)
        _modelManager = StateObject(wrappedValue: manager)
        _listener = StateObject(wrappedValue: speechListener)
        _pilot = StateObject(wrappedValue: conversationPilot)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(modelManager)
                .environmentObject(listener)
                .environmentObject(pilot)
                .preferredColorScheme(.dark)
                .onAppear {
                    pilot.attach(modelContext: sharedModelContainer.mainContext)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
