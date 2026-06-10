import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import SwiftUI

/// Downloads, stores, loads and runs the local language models.
///
/// Weights live in Application Support (excluded from iCloud backup) and are
/// pulled straight from Hugging Face by the in-app downloader. Inference runs
/// through MLX on the GPU — nothing is ever sent off the device.
@MainActor
final class ModelManager: ObservableObject {

    enum ModelState: Equatable {
        case notInstalled
        case downloading(Double)   // 0...1
        case installed
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var states: [String: ModelState] = [:]
    @Published private(set) var loadedModelID: String?
    @AppStorage("myna.activeModelID") var activeModelID: String = ModelCatalog.recommendedID

    private var container: ModelContainer?
    private let hub: HubApi
    private let modelsRoot: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsRoot = support.appendingPathComponent("MynaModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        // Multi-gigabyte weights are re-downloadable; keep them out of iCloud backups.
        var noBackup = modelsRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? noBackup.setResourceValues(values)

        hub = HubApi(downloadBase: modelsRoot)

        // Keep MLX's GPU buffer cache small; an LLM on a phone wants every megabyte.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        refreshInstalledStates()
    }

    // MARK: - State

    var hasAnyModelInstalled: Bool {
        states.values.contains { state in
            switch state {
            case .installed, .ready, .loading: return true
            default: return false
            }
        }
    }

    var activeModel: CatalogModel? { ModelCatalog.model(withID: activeModelID) }

    func state(of model: CatalogModel) -> ModelState {
        states[model.id] ?? .notInstalled
    }

    func refreshInstalledStates() {
        for model in ModelCatalog.all {
            if loadedModelID == model.id {
                states[model.id] = .ready
            } else if isInstalled(model) {
                states[model.id] = .installed
            } else if case .downloading = states[model.id] {
                // leave in-flight downloads alone
            } else {
                states[model.id] = .notInstalled
            }
        }
    }

    private func configuration(for model: CatalogModel) -> ModelConfiguration {
        ModelConfiguration(id: model.id)
    }

    private func directory(for model: CatalogModel) -> URL {
        configuration(for: model).modelDirectory(hub: hub)
    }

    private func isInstalled(_ model: CatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: model).appendingPathComponent("config.json").path)
    }

    func sizeOnDisk(of model: CatalogModel) -> Int64 {
        let dir = directory(for: model)
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    var totalBytesOnDisk: Int64 {
        ModelCatalog.all.reduce(0) { $0 + sizeOnDisk(of: $1) }
    }

    // MARK: - Download / load / delete

    /// Downloads the model from Hugging Face (resumable via the Hub cache) and
    /// warms it up. Safe to call for an already-installed model to just load it.
    func downloadAndLoad(_ model: CatalogModel) {
        switch state(of: model) {
        case .downloading, .loading:
            return
        default:
            break
        }
        states[model.id] = isInstalled(model) ? .loading : .downloading(0)

        Task {
            do {
                let loaded = try await LLMModelFactory.shared.loadContainer(
                    hub: hub,
                    configuration: configuration(for: model)
                ) { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading = self.states[model.id] {
                            self.states[model.id] = .downloading(progress.fractionCompleted)
                        }
                    }
                }
                // Swap the active brain.
                self.container = loaded
                self.loadedModelID = model.id
                self.activeModelID = model.id
                self.refreshInstalledStates()
            } catch {
                self.states[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    func delete(_ model: CatalogModel) {
        if loadedModelID == model.id {
            container = nil
            loadedModelID = nil
        }
        try? FileManager.default.removeItem(at: directory(for: model))
        refreshInstalledStates()
    }

    /// Returns the loaded container, loading the active model from disk if needed.
    private func ensureContainer() async throws -> ModelContainer {
        if let container, loadedModelID == activeModelID {
            return container
        }
        guard let model = activeModel, isInstalled(model) else {
            throw MynaModelError.noModelInstalled
        }
        states[model.id] = .loading
        let loaded = try await LLMModelFactory.shared.loadContainer(
            hub: hub,
            configuration: configuration(for: model)
        )
        container = loaded
        loadedModelID = model.id
        refreshInstalledStates()
        return loaded
    }

    // MARK: - Inference

    /// One-shot generation: a fresh chat session per request keeps long days
    /// from accumulating context (and memory).
    func respond(instructions: String, prompt: String, maxTokens: Int = 2048) async throws -> String {
        let container = try await ensureContainer()
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.3, topP: 0.9)
        let session = ChatSession(container, instructions: instructions, generateParameters: parameters)
        return try await session.respond(to: prompt)
    }
}

enum MynaModelError: LocalizedError {
    case noModelInstalled

    var errorDescription: String? {
        switch self {
        case .noModelInstalled:
            return "No AI model is installed yet. Visit the Model Hub to download one."
        }
    }
}
