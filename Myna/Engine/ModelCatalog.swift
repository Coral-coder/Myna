import Foundation

/// A locally runnable language model Myna knows how to download and drive.
/// All weights come from the mlx-community organization on Hugging Face,
/// pre-quantized to 4-bit for Apple Silicon iPhones.
struct CatalogModel: Identifiable, Hashable {
    let id: String              // Hugging Face repo id, e.g. "mlx-community/Llama-3.2-3B-Instruct-4bit"
    let displayName: String
    let family: String
    let parameters: String
    let downloadGB: Double      // approximate size of weights on disk
    let peakRAMGB: Double       // approximate working-set while generating
    let badge: Badge?
    let blurb: String

    enum Badge: String {
        case recommended = "Recommended"
        case fastest = "Fastest"
        case maxQuality = "Max Quality"
    }
}

enum ModelCatalog {
    /// Default pick for iPhone 15 Pro Max and newer (A17 Pro, 8 GB RAM).
    static let recommendedID = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    static let all: [CatalogModel] = [
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
            blurb: "The most capable mind that comfortably fits an 8 GB iPhone. Slower and hungrier — best when your meetings are dense and your notes need to be forensic."
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
