import SwiftData
import SwiftUI
import UIKit
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

    /// One-time: automatic calendar entries were on by default and fired on
    /// casual conversation. Turn them off for everyone once; it can be switched
    /// back on in Settings.
    private static func resetAutoScheduleOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "myna.autoScheduleReset.v1") else { return }
        defaults.set(false, forKey: "myna.autoSchedule")
        defaults.set(true, forKey: "myna.autoScheduleReset.v1")
    }

    private init() {
        CrashReporter.shared.start()
        Self.restoreOnDeviceListening()
        Self.resetAutoScheduleOnce()
        container = Self.makeContainer()

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
        TranscriptionLab.shared.attach(listener: listener, container: container)
        HomeSync.shared.start(container: container)
        MusicSpotter.shared.attach(container: container)
        // When the home server comes back, write up what was waiting for it.
        HomeServer.shared.onBack = { [pilot] in pilot.drainQueue() }
        TranscriptSorter.shared.start(container: container) { [modelManager] instructions, prompt in
            try await modelManager.respond(instructions: instructions, prompt: prompt, maxTokens: 80, background: true)
        }
        beeCloud.brain = brain
        // Extraction runs on the user's downloaded model (a bigger MLX model when
        // installed and on screen, Apple Intelligence otherwise). Foreground only.
        beeCloud.generate = { [modelManager] instructions, prompt in
            try await modelManager.respond(instructions: instructions, prompt: prompt, maxTokens: 1200)
        }
        // The bracelet's key is sealed by Bee, so fetch it with the connected
        // Bee account when provisioning. Nil (not connected) leaves the bracelet
        // card telling the user to connect Bee first.
        bee.fetchSecureKeyToken = { [beeCloud] deviceIDHex in
            try await beeCloud.braceletKeyToken(deviceIDHex: deviceIDHex)
        }
        // The linked Bee account's token doubles as the session token for the
        // automatic key fetch, so a linked account needs no pasted token.
        bee.linkedSessionToken = { [beeCloud] in beeCloud.storedToken }
        // When the bracelet's key can't be fetched, Myna removes the bracelet and
        // falls back to syncing conversations from Bee's cloud instead.
        bee.onSyncFallback = { [beeCloud] in beeCloud.importIfEnabled() }
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
        // NB: Whisper is intentionally NOT warmed up here. Loading its model is a
        // memory spike, and doing it on the synchronous launch path is exactly
        // what gets a cold launch (e.g. tapping a notification) jetsam-killed.
        // becameActive() loads it once the app is settled and foreground.
        Self.sharedIfReady = self
    }

    /// Open the SwiftData store, resiliently. A cold launch (tapping a
    /// notification) can race a still-suspended prior instance that holds the
    /// SQLite file lock, which made `ModelContainer(for:)` throw and the old
    /// `fatalError` crash the app on every such launch. Retry briefly; if the
    /// store truly won't open, fall back to an in-memory store so the app still
    /// opens (a later clean launch recovers the on-disk data) rather than
    /// crash-looping.
    private static func makeContainer() -> ModelContainer {
        for attempt in 0..<4 {
            do {
                return try ModelContainer(for: ConversationNote.self, MynaItem.self, PendingConversation.self, Suggestion.self, Memory.self, Utterance.self, VoicePerson.self, HeardSong.self)
            } catch {
                CrashReporter.log("ModelContainer attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.25) }
            }
        }
        if let fallback = try? ModelContainer(
            for: ConversationNote.self, MynaItem.self, PendingConversation.self, Suggestion.self, Memory.self, Utterance.self, VoicePerson.self, HeardSong.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        ) {
            CrashReporter.log("ModelContainer: in-memory fallback (on-disk store unavailable this launch).")
            return fallback
        }
        fatalError("Could not create SwiftData container after retries.")
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
        beeRefresh.schedule()
        waker.apply()
        if alwaysOn, micEnabled, UserDefaults.standard.bool(forKey: "myna.onboarded"), SpeechListener.hasPermissions,
           pilot.phase == .idle, !listener.isListening {
            pilot.startListening()
        }
        // Heavy work — composing queued conversations (loads the on-device model)
        // and pulling from Bee — must NOT run on the launch-critical window. When
        // iOS cold-launches Myna from a notification tap, doing it inline can trip
        // the launch watchdog and the app is killed ("crashes on opening a
        // notification"). Defer it until the app has settled and is still active.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, UIApplication.shared.applicationState == .active else { return }
            if self.whisper.isEnabled { self.whisper.load() }
            self.beeCloud.importIfEnabled()
            self.pilot.drainQueue()
        }
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
    // These are the completion-handler forms on purpose. With the `async`
    // forms, Swift calls the system's completion handler from a background
    // thread when the method returns, and UIKit requires it on the main thread:
    // tapping a notification raised an exception there and ended the app
    // (build 99, and the earlier "notification" crashes).

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if Thread.isMainThread {
            completionHandler([.banner, .list, .sound])
        } else {
            DispatchQueue.main.async { completionHandler([.banner, .list, .sound]) }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            defer { completionHandler() }
            guard action == ActionNotifier.undoActionID, let undo = ActionUndo(payload: userInfo) else { return }
            // Only act once services are fully initialised. Never force a
            // first-time AppServices init from the notification-delivery path.
            guard let services = AppServices.sharedIfReady else { return }
            // EventKit / CoreData calls in `undo` can raise an Objective-C
            // NSException, which Swift cannot catch; run the work inside an
            // ObjC @try/@catch so a raised exception is logged, never fatal.
            if let reason = MynaExceptionCatcher.catching({
                services.brain.undo(undo)
                services.brain.notifier.clearDelivered(identifier)
            }) {
                CrashReporter.log("Undo from notification raised, ignored: \(reason)")
            }
        }
    }
}
