import SwiftData
import SwiftUI
import UserNotifications

/// Everything Myna runs on, created once and shared by the app, its views and
/// Siri / Shortcuts intents.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let container: ModelContainer
    let modelManager: ModelManager
    let listener: SpeechListener
    let pilot: ConversationPilot
    let brain: MynaBrain
    let contextHub: ContextHub
    let bee: BeeManager
    let beeCloud: BeeCloudImporter
    let beeRefresh: BeeBackgroundRefresh
    let waker: BackgroundWaker
    let whisper: WhisperTranscriber
    let neuralVoice: NeuralVoice
    private let notificationPresenter = NotificationPresenter()

    /// Start listening on launch so Myna is simply always there.
    var alwaysOn: Bool {
        UserDefaults.standard.object(forKey: "myna.alwaysOn") as? Bool ?? true
    }

    /// Whether Myna may use the iPhone microphone at all. Myna is now a Bee
    /// companion — it imports your Bee conversations and turns them into
    /// suggestions — so the mic is OFF by default and nothing is ever recorded
    /// on this phone unless you deliberately turn it back on in Backstage.
    var micEnabled: Bool {
        UserDefaults.standard.object(forKey: "myna.micEnabled") as? Bool ?? false
    }

    /// Wake word setting key, and how its text becomes a word list.
    static let wakeWordKey = "myna.customWakeWord"

    static func applyCustomWakeWords() {
        let raw = UserDefaults.standard.string(forKey: wakeWordKey) ?? ""
        CommandParser.customWakeWords = raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private init() {
        do {
            container = try ModelContainer(for: ConversationNote.self, MynaItem.self, PendingConversation.self, Suggestion.self)
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }

        Self.applyCustomWakeWords()
        modelManager = ModelManager()
        listener = SpeechListener()
        contextHub = ContextHub()
        pilot = ConversationPilot(listener: listener, modelManager: modelManager, contextHub: contextHub)
        brain = MynaBrain(listener: listener, modelManager: modelManager, pilot: pilot, contextHub: contextHub)
        bee = BeeManager(listener: listener, pilot: pilot)
        beeCloud = BeeCloudImporter()
        beeRefresh = BeeBackgroundRefresh(importer: beeCloud, pilot: pilot)
        waker = BackgroundWaker(importer: beeCloud, refresh: beeRefresh)
        whisper = WhisperTranscriber()
        neuralVoice = NeuralVoice()

        pilot.brain = brain
        beeCloud.brain = brain
        // Extraction runs on the user's downloaded model (a bigger MLX model when
        // installed and on screen, Apple Intelligence otherwise). Foreground only.
        beeCloud.generate = { [modelManager] instructions, prompt in
            try await modelManager.respond(instructions: instructions, prompt: prompt, maxTokens: 1200)
        }
        pilot.whisper = whisper
        brain.voice.neural = neuralVoice

        let context = container.mainContext
        pilot.attach(modelContext: context)
        brain.attach(modelContext: context)
        beeCloud.attach(modelContext: context)

        UNUserNotificationCenter.current().delegate = notificationPresenter
        ActionNotifier.registerCategory()
        // Must register during launch, before the app finishes launching.
        beeRefresh.register()
        // Location-driven wake-ups so Bee is checked while Myna is closed.
        waker.apply()
        // Warm up Whisper if the user turned it on previously.
        if whisper.isEnabled { whisper.load() }
    }

    /// First launch after onboarding, and every return to the foreground.
    func becameActive() {
        modelManager.refreshInstalledStates()
        beeCloud.importIfEnabled()
        beeRefresh.schedule()
        waker.apply()
        if alwaysOn, micEnabled, UserDefaults.standard.bool(forKey: "myna.onboarded"), SpeechListener.hasPermissions,
           pilot.phase == .idle, !listener.isListening {
            pilot.startListening()
        }
        pilot.drainQueue()
    }

    /// Entered the background: ask iOS to wake us later to pull from Bee.
    func enteredBackground() {
        beeRefresh.schedule()
    }
}

/// Shows Myna's reminders as banners even while the app is open, and carries out
/// the Cancel button on an action notification (from the iPhone or Apple Watch).
private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == ActionNotifier.undoActionID,
              let undo = ActionUndo(payload: response.notification.request.content.userInfo) else { return }
        let identifier = response.notification.request.identifier
        await MainActor.run {
            AppServices.shared.brain.undo(undo)
            AppServices.shared.brain.notifier.clearDelivered(identifier)
        }
    }
}
