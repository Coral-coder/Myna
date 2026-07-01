import SwiftData
import SwiftUI

@main
struct MynaApp: App {
    private let sharedModelContainer: ModelContainer
    @StateObject private var modelManager: ModelManager
    @StateObject private var transcriber: WhisperTranscriber
    @StateObject private var capture: AudioCaptureEngine
    @StateObject private var pilot: ConversationPilot

    init() {
        do {
            sharedModelContainer = try ModelContainer(for: ConversationNote.self)
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }

        let manager = ModelManager()
        let whisper = WhisperTranscriber()
        let audio = AudioCaptureEngine()
        let conversationPilot = ConversationPilot(capture: audio, transcriber: whisper, modelManager: manager)
        _modelManager = StateObject(wrappedValue: manager)
        _transcriber = StateObject(wrappedValue: whisper)
        _capture = StateObject(wrappedValue: audio)
        _pilot = StateObject(wrappedValue: conversationPilot)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(modelManager)
                .environmentObject(transcriber)
                .environmentObject(capture)
                .environmentObject(pilot)
                .preferredColorScheme(.dark)
                .onAppear {
                    pilot.attach(modelContext: sharedModelContainer.mainContext)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
