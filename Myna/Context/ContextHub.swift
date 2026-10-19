import Foundation

/// On-device context from the rest of the iPhone — where you are, who you're
/// talking about, how you slept, what you photographed — used to enrich notes
/// and the assistant's answers.
///
/// Every source is off until you switch it on in Backstage, which is also when
/// iOS asks for permission. Nothing gathered here is uploaded; it is read when
/// a note is composed or a question is asked and only the result (a place
/// name, the people mentioned, photo references) is saved with the note.
@MainActor
final class ContextHub: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case location, contacts, health, photos

        var id: String { rawValue }
        var defaultsKey: String { "myna.context.\(rawValue)" }
    }

    let location = LocationContext()
    let contacts = ContactsContext()
    let health = HealthContext()
    let photos = PhotosContext()

    /// Name places that aren't saved ones via Apple's geocoder (sends coordinates to Apple).
    static let geocodingKey = "myna.context.placeNames"

    var allowsGeocoding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.geocodingKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.geocodingKey)
        }
    }

    /// Switched on in Backstage *and* still permitted by iOS.
    func isEnabled(_ source: Source) -> Bool {
        UserDefaults.standard.bool(forKey: source.defaultsKey) && isPermitted(source)
    }

    func isPermitted(_ source: Source) -> Bool {
        switch source {
        case .location: return location.isAuthorized
        case .contacts: return contacts.isAuthorized
        case .health: return HealthContext.isAvailable && health.hasRequested
        case .photos: return photos.isAuthorized
        }
    }

    /// Turns a source on (asking iOS for permission the first time) or off.
    /// Returns whether it ended up on.
    @discardableResult
    func setEnabled(_ source: Source, _ enabled: Bool) async -> Bool {
        var granted = false
        if enabled {
            switch source {
            case .location: granted = await location.requestAccess()
            case .contacts: granted = await contacts.requestAccess()
            case .health: granted = await health.requestAccess()
            case .photos: granted = await photos.requestAccess()
            }
        }
        objectWillChange.send()
        UserDefaults.standard.set(enabled && granted, forKey: source.defaultsKey)
        return enabled && granted
    }

    // MARK: - For notes

    /// Where you are right now, as a name; empty when unknown or switched off.
    func placeName() async -> String {
        guard isEnabled(.location) else { return "" }
        return await location.placeName(allowGeocoding: allowsGeocoding)
    }

    /// Context for a finished conversation. `place` is captured when the
    /// conversation ends, since a queued one may be composed hours later.
    func noteContext(transcript: String, startedAt: Date, endedAt: Date, place: String) async -> NoteContext {
        var context = NoteContext(place: place)
        if isEnabled(.contacts) {
            context.people = await contacts.index().mentions(in: transcript)
        }
        if isEnabled(.photos) {
            let assets = photos.photos(from: startedAt, to: endedAt)
            context.photoIdentifiers = assets.map(\.localIdentifier)
            context.photoText = await photos.recognizedText(in: assets)
        }
        return context
    }

    // MARK: - For the assistant

    /// Extra context lines for a question — each source contributes only what
    /// the question needs.
    func assistantLines(for question: String) async -> [String] {
        var lines: [String] = []
        let place = await placeName()
        if !place.isEmpty {
            lines.append("WHERE THE USER IS NOW: \(place)")
        }
        if isEnabled(.contacts) {
            let people = await contacts.index().mentions(in: question, limit: 6)
            if !people.isEmpty {
                lines.append("PEOPLE MENTIONED (from the user's contacts): " + people.map(\.summary).joined(separator: "; "))
            }
        }
        if isEnabled(.health), HealthMath.isHealthQuestion(question), let summary = await health.summary() {
            lines.append(summary)
        }
        return lines
    }
}
