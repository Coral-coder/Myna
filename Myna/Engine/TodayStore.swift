import Foundation

/// Keeps the Today page in step with the server. While Today is on screen it
/// pulls the server's live view of the day (transcript, numbers, word cloud)
/// every few seconds, so the page reflects what the server actually has — Bee
/// conversations included — instead of a stale local copy. When the server
/// can't be reached, `feed` goes nil and Today falls back to its on-device view.
@MainActor
final class TodayStore: ObservableObject {
    static let shared = TodayStore()

    @Published private(set) var feed: HomeServer.TodayFeed?
    @Published private(set) var lastError: String?

    private init() {}

    /// True when the server answered and its view should be shown.
    var live: Bool { feed != nil }

    func refresh() async {
        let server = HomeServer.shared
        guard server.isPaired, server.enabled, server.reachable == true else {
            feed = nil
            return
        }
        do {
            feed = try await server.today()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            // Keep the last good feed on a transient hiccup rather than blanking.
        }
    }
}
