import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device foundation model (iOS 26+). Unlike MLX — whose GPU work
/// iOS forbids in the background on iPhone — it keeps running while the phone
/// is locked, within a system budget, which is what lets Myna stay useful all
/// day from a pocket.
enum AppleIntelligenceEngine {

    /// Rough context the model can take in one go (its window is 4,096 tokens).
    static let promptCharacterBudget = 5_500

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Why the model can't be used right now, in plain words.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This iPhone doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in Settings to use it."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading its model."
            case .unavailable:
                return "Apple Intelligence isn't available right now."
            }
        }
        #endif
        return "Requires iOS 26 or later."
    }

    static func respond(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: min(maxTokens, 1_800))
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        }
        #endif
        throw MynaModelError.appleIntelligenceUnavailable
    }
}
