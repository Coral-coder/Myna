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
    private let notificationPresenter = NotificationPresenter()

    /// Start listening on launch so Myna is simply always there.
    var alwaysOn: Bool {
        UserDefaults.standard.object(forKey: "myna.alwaysOn") as? Bool ?? true
    }

    private init() {
        do {
            container = try ModelContainer(for: ConversationNote.self, MynaItem.self, PendingConversation.self)
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }

        modelManager = ModelManager()
        listener = SpeechListener()
        contextHub = ContextHub()
        pilot = ConversationPilot(listener: listener, modelManager: modelManager, contextHub: contextHub)
        brain = MynaBrain(listener: listener, modelManager: modelManager, pilot: pilot, contextHub: contextHub)

        pilot.brain = brain

        let context = container.mainContext
        pilot.attach(modelContext: context)
        brain.attach(modelContext: context)

        UNUserNotificationCenter.current().delegate = notificationPresenter
    }

    /// First launch after onboarding, and every return to the foreground.
    func becameActive() {
        modelManager.refreshInstalledStates()
        if alwaysOn, UserDefaults.standard.bool(forKey: "myna.onboarded"), SpeechListener.hasPermissions,
           pilot.phase == .idle, !listener.isListening {
            pilot.startListening()
        }
        pilot.drainQueue()
    }
}

/// Shows Myna's reminders as banners even while the app is open.
private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
