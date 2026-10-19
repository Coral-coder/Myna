import Foundation

/// A locally runnable language model Myna knows how to download and drive.
/// All weights come from the mlx-community organization on Hugging Face,
/// pre-quantized to 4-bit for Apple Silicon iPhones.
struct CatalogModel: Identifiable, Hashable {
    let id: String              // Hugging Face repo id, e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit"
    var backend: Backend = .mlx
    let displayName: String
    let family: String
    let parameters: String
    let downloadGB: Double      // approximate size of weights on disk
    let peakRAMGB: Double       // approximate working-set while generating
    let badge: Badge?
    let blurb: String
    /// Smallest iPhone memory (GB) this model is offered on.
    var minimumDeviceRAMGB: Double = 6

    enum Badge: String {
        case recommended = "Recommended"
        case fastest = "Fastest"
        case maxQuality = "Max Quality"
        case mostPowerful = "Most Powerful"
        case builtIn = "Built In"
    }

    enum Backend: Hashable {
        /// Downloaded weights run through MLX on the GPU (foreground only on iPhone).
        case mlx
        /// Apple's on-device foundation model (iOS 26+, Apple Intelligence on).
        /// Nothing to download, and it keeps working while the phone is locked.
        case appleFoundation
    }

    /// Whether this iPhone has enough memory to run the model comfortably.
    var fitsThisDevice: Bool {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 >= minimumDeviceRAMGB - 0.5
    }

    /// Qwen 3 reasons out loud by default; Myna wants the answer, not the musing.
    var wantsThinkingDisabled: Bool { id.lowercased().contains("qwen3") }
}

enum ModelCatalog {
    /// Default pick for iPhone 15 Pro Max and newer (A17 Pro, 8 GB RAM).
    static let recommendedID = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    static let appleFoundationID = "apple/foundation-model"

    static let all: [CatalogModel] = [
        CatalogModel(
            id: appleFoundationID,
            backend: .appleFoundation,
            displayName: "Apple Intelligence",
            family: "Apple Foundation Model",
            parameters: "~3B · built in",
            downloadGB: 0,
            peakRAMGB: 0,
            badge: .builtIn,
            blurb: "Apple's own on-device model, already on your iPhone with iOS 26. Nothing to download, light on battery, and the only mind that can keep composing notes while the phone is locked in your pocket. Myna also uses it as a background helper when your main model needs the screen on."
        ),
        CatalogModel(
            id: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen 3 8B",
            family: "Alibaba Qwen",
            parameters: "8B · 4-bit",
            downloadGB: 4.6,
            peakRAMGB: 5.6,
            badge: .mostPowerful,
            blurb: "The most powerful mind Myna can run on a phone: sharper reasoning, better follow-through on long meetings, and the best answers when you ask Myna questions. Needs a 12 GB iPhone (iPhone 17 Pro / Pro Max or newer).",
            minimumDeviceRAMGB: 12
        ),
        CatalogModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B Instruct",
            family: "Meta Llama",
            parameters: "3B · 4-bit",
            downloadGB: 1.8,
            peakRAMGB: 2.6,
            badge: .recommended,
            blurb: "The sweet spot for all-day note taking on an iPhone 15 Pro Max: detailed, reliable structured notes at ~20 tokens/sec, with headroom left for the rest of the system."
        ),
        CatalogModel(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            displayName: "Qwen 2.5 3B Instruct",
            family: "Alibaba Qwen",
            parameters: "3B · 4-bit",
            downloadGB: 1.7,
            peakRAMGB: 2.5,
            badge: nil,
            blurb: "A strong alternative scribe — particularly good at extracting dates, numbers and commitments, and at multilingual conversations."
        ),
        CatalogModel(
            id: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen 3 4B",
            family: "Alibaba Qwen",
            parameters: "4B · 4-bit",
            downloadGB: 2.3,
            peakRAMGB: 3.4,
            badge: .maxQuality,
            blurb: "The most capable mind that comfortably fits an 8 GB iPhone. Slower and hungrier — best when your meetings are dense and your notes need to be forensic.",
            minimumDeviceRAMGB: 8
        ),
        CatalogModel(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            displayName: "Llama 3.2 1B Instruct",
            family: "Meta Llama",
            parameters: "1B · 4-bit",
            downloadGB: 0.7,
            peakRAMGB: 1.2,
            badge: .fastest,
            blurb: "Featherweight battery saver. Notes are lighter on nuance, but summaries land in seconds and it sips power during a long day."
        ),
    ]

    static func model(withID id: String) -> CatalogModel? {
        all.first { $0.id == id }
    }
}
