import BackgroundTasks
import Foundation

/// Keeps Myna working while it's in your pocket, no microphone required.
///
/// iOS wakes the app briefly in the background; we use that window to pull from
/// the Bee backend — account, learned facts, and any new conversations, filed as
/// notes — then schedule the next wake-up. This is how "the AI runs in the
/// background off Bee" without the phone ever opening its own mic.
@MainActor
final class BeeBackgroundRefresh {
    /// Also listed under `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskID = "com.lightwave.myna.bee-refresh"

    /// Don't ask iOS to wake us more often than this; it decides the real cadence.
    private static let minInterval: TimeInterval = 15 * 60

    private let importer: BeeCloudImporter
    private let pilot: ConversationPilot

    init(importer: BeeCloudImporter, pilot: ConversationPilot) {
        self.importer = importer
        self.pilot = pilot
    }

    /// Register the task handler. Call once, during launch.
    func register() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: nil) { [weak self] task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // The scheduler may call this off the main thread; hop on.
            Task { @MainActor in self?.handle(refresh) }
        }
    }

    /// Ask iOS to wake Myna again later. Harmless if background refresh is off
    /// or we're on a simulator — the submit simply fails and we move on.
    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGAppRefreshTask) {
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
