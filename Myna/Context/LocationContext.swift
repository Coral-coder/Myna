import CoreLocation
import Foundation

/// Where a conversation happened, named the way you'd name it.
///
/// Uses "When In Use" location at city-block accuracy. By default a fix is only
/// ever compared against the places you've saved (Home, Work, …), which live in
/// the Keychain — so the location never leaves the iPhone. Naming other places
/// through Apple's geocoder is a separate opt-in, because that sends the
/// coordinates to Apple.
@MainActor
final class LocationContext: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var places: [SavedPlace]

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var authorizationWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var fixRound = 0

    private static let placesAccount = "context.savedPlaces"

    override init() {
        places = Keychain.value([SavedPlace].self, for: Self.placesAccount) ?? []
        super.init()
        authorization = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestAccess() async -> Bool {
        guard authorization == .notDetermined else { return isAuthorized }
        let status = await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    /// A recent fix: a fresh one when iOS will give it, otherwise the last one
    /// it had if that is under half an hour old (iOS withholds new fixes from
    /// "When In Use" apps that are running in the background).
    func currentLocation() async -> CLLocation? {
        guard isAuthorized else { return nil }
        if let cached = manager.location, cached.timestamp.timeIntervalSinceNow > -120 {
            return cached
        }
        if let fresh = await requestFix(timeout: .seconds(10)) {
            return fresh
        }
        if let cached = manager.location, cached.timestamp.timeIntervalSinceNow > -1800 {
            return cached
        }
        return nil
    }

    /// The name for where you are: a saved place, or — only with
    /// `allowGeocoding` — what Apple Maps calls it. Empty when unknown.
    func placeName(allowGeocoding: Bool) async -> String {
        guard let location = await currentLocation() else { return "" }
        let coordinate = location.coordinate
        if let saved = SavedPlace.nearest(toLatitude: coordinate.latitude, longitude: coordinate.longitude, in: places) {
            return saved.name
        }
        guard allowGeocoding else { return "" }
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return "" }
        let area = placemark.areasOfInterest?.first
        let name = placemark.name.flatMap { $0 == placemark.thoroughfare ? nil : $0 }
        return [area ?? name, placemark.locality].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - Saved places

    /// Saves where you are now under `name`. Returns false when there's no fix.
    @discardableResult
    func saveCurrentPlace(named name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let location = await currentLocation() else { return false }
        var updated = places.filter { $0.name.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.append(SavedPlace(
            name: trimmed,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            radius: max(100, min(location.horizontalAccuracy * 2, 300))
        ))
        return store(updated)
    }

    func removePlace(_ place: SavedPlace) {
        store(places.filter { $0.id != place.id })
    }

    @discardableResult
    private func store(_ updated: [SavedPlace]) -> Bool {
        do {
            if updated.isEmpty {
                Keychain.delete(Self.placesAccount)
            } else {
                try Keychain.set(updated, for: Self.placesAccount)
            }
            places = updated
            return true
        } catch {
            return false
        }
    }

    // MARK: - One-shot fixes

    private func requestFix(timeout: Duration) async -> CLLocation? {
        await withCheckedContinuation { continuation in
            fixWaiters.append(continuation)
            guard fixWaiters.count == 1 else { return }
            fixRound += 1
            let round = fixRound
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, self.fixRound == round else { return }
                self.resolveFix(nil)
            }
        }
    }

    private func resolveFix(_ location: CLLocation?) {
        let waiters = fixWaiters
        fixWaiters = []
        fixRound += 1
        waiters.forEach { $0.resume(returning: location) }
    }
}

extension LocationContext: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            guard status != .notDetermined else { return }
            let waiters = self.authorizationWaiters
            self.authorizationWaiters = []
            waiters.forEach { $0.resume(returning: status) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in self.resolveFix(latest) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolveFix(nil) }
    }
}
