import Foundation

/// A local Whisper speech-recognition model Myna can download and run.
///
/// `variant` is the folder name inside the `argmaxinc/whisperkit-coreml`
/// Hugging Face repo — WhisperKit downloads and runs the Core ML build of that
/// model on the Apple Neural Engine.
struct WhisperModel: Identifiable, Hashable {
    let id: String            // == variant
    var variant: String { id }
    let displayName: String
    let approxMB: Int
    let multilingual: Bool
    let badge: Badge?
    let blurb: String

    enum Badge: String {
        case recommended = "Recommended"
        case fastest = "Fastest"
        case maxQuality = "Max Accuracy"
    }
}

enum WhisperCatalog {
    /// Default "ears" for iPhone 15 Pro Max: fast, English, gentle on battery.
    static let recommendedID = "openai_whisper-base.en"

    static let all: [WhisperModel] = [
        WhisperModel(
            id: "openai_whisper-base.en",
            displayName: "Whisper Base (English)",
            approxMB: 145,
            multilingual: false,
            badge: .recommended,
            blurb: "The all-day sweet spot: transcribes English conversations faster than real time on the Neural Engine while sipping battery. Ideal for meeting notes."
        ),
        WhisperModel(
            id: "openai_whisper-small.en",
            displayName: "Whisper Small (English)",
            approxMB: 470,
            multilingual: false,
            badge: nil,
            blurb: "Noticeably sharper on names, jargon and crosstalk than Base, for a modest extra memory and battery cost. A great step up for dense meetings."
        ),
        WhisperModel(
            id: "openai_whisper-large-v3-v20240930_626MB",
            displayName: "Whisper Large v3 Turbo",
            approxMB: 626,
            multilingual: true,
            badge: .maxQuality,
            blurb: "State-of-the-art accuracy across 99 languages, distilled and quantized for the Neural Engine. The most faithful transcripts; heaviest on battery."
        ),
        WhisperModel(
            id: "openai_whisper-tiny.en",
            displayName: "Whisper Tiny (English)",
            approxMB: 75,
            multilingual: false,
            badge: .fastest,
            blurb: "Featherweight and near-instant. Best when battery life matters most and conversations are clear; less robust to accents and noise."
        ),
    ]

    static func model(withID id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
