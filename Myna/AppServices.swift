import SwiftData
import SwiftUI
import UserNotifications

/// Everything Myna runs on, created once and shared by the app, its views and
/// Siri / Shortcuts intents.
@MainActor
final class AppServices {
    static let shared = AppServices()
    /// Set once `shared` has finished initialising (read by the crash heartbeat).
    private(set) static var sharedIfReady: AppServices?

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

    /// Whether Myna may use the iPhone microphone. On by default: Myna records
    /// and transcribes on this phone, in the background too.
    var micEnabled: Bool {
        UserDefaults.standard.object(forKey: "myna.micEnabled") as? Bool ?? true
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
        CrashReporter.shared.start()
        Self.restoreOnDeviceListening()
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
        Self.sharedIfReady = self
    }

    /// One-time: the Bee-companion builds turned the mic and Whisper off. Turn
    /// them back on — on-device recording is Myna's job again.
    private static func restoreOnDeviceListening() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "myna.listeningRestored.v1") else { return }
        defaults.set(true, forKey: "myna.micEnabled")
        defaults.set(true, forKey: "myna.alwaysOn")
        defaults.set(true, forKey: WhisperTranscriber.enabledKey)
        defaults.set(true, forKey: "myna.listeningRestored.v1")
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

    /// Entered the background: keep recording (background audio mode), drop
    /// the big MLX model from memory so iOS doesn't kill Myna to reclaim it.
    func enteredBackground() {
        beeRefresh.schedule()
        modelManager.releaseForBackground()
        CrashReporter.log("background — listening=\(listener.isListening) memory=\(CrashReporter.memoryFootprintMB())MB")
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
