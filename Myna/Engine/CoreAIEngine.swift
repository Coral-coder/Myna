import CoreAILanguageModels
import Foundation
import FoundationModels

/// Runs an open language model on the Neural Engine through Apple's Core AI
/// runtime (iOS 27). Unlike MLX, which needs the GPU, this keeps working with
/// Myna in the background and the phone locked — the app holds the Background
/// Inference entitlement for exactly that.
actor CoreAIEngine {
    static let shared = CoreAIEngine()

    private var model: CoreAILanguageModel?
    private var loadedPath: String?

    /// The exported models are built with a 4,096-token window, shared between
    /// what goes in and what comes out.
    static let promptCharacterBudget = 3_500
    static let maximumResponseTokens = 1_400

    func respond(modelFolder: URL, instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        if loadedPath != modelFolder.path || model == nil {
            model?.unload()
            model = nil
            model = try await CoreAILanguageModel(resourcesAt: modelFolder)
            loadedPath = modelFolder.path
        }
        guard let model else { throw MynaModelError.noModelInstalled }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: min(maxTokens, Self.maximumResponseTokens))
        let response = try await session.respond(to: prompt, options: options)
        return Self.withoutThinking(response.content)
    }

    /// Free the model's memory (it reloads on next use).
    func unload() {
        model?.unload()
        model = nil
        loadedPath = nil
    }

    /// Drop any reasoning a "thinking" model wrote before its answer.
    private static func withoutThinking(_ text: String) -> String {
        var out = text
        while let start = out.range(of: "<think>"), let end = out.range(of: "</think>", range: start.upperBound..<out.endIndex) {
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
