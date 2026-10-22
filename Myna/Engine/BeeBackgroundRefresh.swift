import BackgroundTasks
import Foundation

/// Keeps Myna working while it's in your pocket, no microphone required.
///
/// Two kinds of background time from iOS, both used to pull new Bee
/// conversations, act on them and notify you:
/// - an app-refresh task (short, frequent as iOS allows), and
/// - a processing task (longer; iOS runs it when the phone is idle, e.g. on
///   the charger), which gives Apple Intelligence room to read conversations.
/// `BackgroundWaker` adds location-driven wake-ups on top, since iOS can be
/// stingy with app refresh for apps you rarely open.
@MainActor
final class BeeBackgroundRefresh {
    /// Both listed under `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskID = "com.lightwave.myna.bee-refresh"
    static let processingID = "com.lightwave.myna.bee-process"

    /// Don't ask iOS to wake us more often than this; it decides the real cadence.
    private static let minInterval: TimeInterval = 15 * 60

    private let importer: BeeCloudImporter
    private let pilot: ConversationPilot

    init(importer: BeeCloudImporter, pilot: ConversationPilot) {
        self.importer = importer
        self.pilot = pilot
    }

    /// Register the task handlers. Call once, during launch.
    func register() {
        for id in [Self.taskID, Self.processingID] {
            _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] task in
                // The scheduler may call this off the main thread; hop on.
                Task { @MainActor in self?.handle(task) }
            }
        }
    }

    /// Ask iOS to wake Myna again later. Harmless if background refresh is off
    /// or we're on a simulator — the submit simply fails and we move on.
    func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: Self.taskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: Self.minInterval)
        try? BGTaskScheduler.shared.submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: Self.processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: Self.minInterval)
        try? BGTaskScheduler.shared.submit(processing)
    }

    private func handle(_ task: BGTask) {
        schedule() // chain the next wake-up before doing the work

        let work = Task { @MainActor in
            await importer.backgroundRefresh()
            // Compose anything the mic queued earlier that couldn't run then.
            pilot.drainQueue()
        }
        task.expirationHandler = { work.cancel() }

        Task { @MainActor in
            _ = await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }
}
