import CoreLocation
import UIKit

/// Wakes Myna in the background as you go about your day, so new Bee
/// conversations get acted on without opening the app.
///
/// iOS only grants app-refresh time sparingly. Significant-location-change
/// monitoring is the reliable alternative: iOS wakes (or even relaunches) the
/// app whenever you move a meaningful distance, which on a normal day is many
/// times. Each wake pulls from Bee (throttled), acts on what it finds and posts
/// notifications. Only coarse movement is used, nothing is stored, and it needs
/// "Always" location permission.
@MainActor
final class BackgroundWaker: NSObject {
    static let enabledKey = "myna.backgroundWake"

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private let manager = CLLocationManager()
    private let importer: BeeCloudImporter
    private let refresh: BeeBackgroundRefresh
    /// Don't hit Bee more often than this from location wakes.
    private static let minGap: TimeInterval = 10 * 60
    private var lastRun: Date = .distantPast

    init(importer: BeeCloudImporter, refresh: BeeBackgroundRefresh) {
        self.importer = importer
        self.refresh = refresh
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
    }

    /// Start (or stop) monitoring to match the setting and permission. Safe to
    /// call repeatedly; called at launch and whenever the toggle changes.
    func apply() {
        guard isEnabled, CLLocationManager.significantLocationChangeMonitoringAvailable() else {
            manager.stopMonitoringSignificantLocationChanges()
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            manager.startMonitoringSignificantLocationChanges()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Escalate to Always so iOS can wake us in the background.
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    var statusText: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: return "On — Myna checks Bee as you move around."
        case .authorizedWhenInUse: return "Needs location set to “Always” in Settings › Myna to wake in the background."
        case .denied, .restricted: return "Location is off for Myna, so background checks rely on iOS alone."
        default: return "Grant location access to let Myna check Bee in the background."
        }
    }

    private func wake() {
        guard isEnabled, Date.now.timeIntervalSince(lastRun) >= Self.minGap else { return }
        lastRun = .now
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "myna.bee-wake") {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        Task { @MainActor in
            await importer.backgroundRefresh()
            refresh.schedule()
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        }
    }
}

extension BackgroundWaker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.apply() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.wake() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
