import Foundation

/// A speaking voice Myna can use, in a form that's free of AVFoundation so the
/// selection and ordering logic is unit-tested off-device. `VoiceReply` maps
/// each installed `AVSpeechSynthesisVoice` to one of these.
struct VoiceOption: Equatable, Identifiable {
    enum Quality: Int, Comparable {
        case standard = 0   // compact / default
        case enhanced = 1
        case premium = 2    // the "Siri-quality" downloadable voices

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .standard: return "Standard"
            case .enhanced: return "Enhanced"
            case .premium: return "Premium"
            }
        }
    }

    var id: String          // AVSpeechSynthesisVoice.identifier
    var name: String
    var quality: Quality
    var language: String    // BCP-47, e.g. "en-US"
}

enum VoiceCatalog {
    /// The voice to speak with: the user's explicit pick if it's still installed,
    /// otherwise the best available for their language — highest quality wins,
    /// preferring an exact language match, then the same language family.
    static func select(identifier: String?, from voices: [VoiceOption], preferredLanguage: String) -> VoiceOption? {
        if let identifier, !identifier.isEmpty, let exact = voices.first(where: { $0.id == identifier }) {
            return exact
        }
        let sorted = byQualityThenName(voices)
        let prefix = String(preferredLanguage.prefix(2))
        return sorted.first { $0.language == preferredLanguage }
            ?? sorted.first { $0.language.hasPrefix(prefix) }
            ?? sorted.first
    }

    /// Voices to offer in the picker: only the user's language family, best
    /// first — highest quality, then an exact language match, then by name.
    static func ordered(_ voices: [VoiceOption], preferredLanguage: String) -> [VoiceOption] {
        let prefix = String(preferredLanguage.prefix(2))
        let family = voices.filter { $0.language.hasPrefix(prefix) }
        let pool = family.isEmpty ? voices : family
        return pool.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            let lExact = lhs.language == preferredLanguage
            let rExact = rhs.language == preferredLanguage
            if lExact != rExact { return lExact }
            return lhs.name < rhs.name
        }
    }

    private static func byQualityThenName(_ voices: [VoiceOption]) -> [VoiceOption] {
        voices.sorted { lhs, rhs in
            lhs.quality != rhs.quality ? lhs.quality > rhs.quality : lhs.name < rhs.name
        }
    }
}
