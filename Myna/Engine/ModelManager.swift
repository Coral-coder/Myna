import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import SwiftUI
import UIKit
import ZIPFoundation

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
        ModelCatalog.all.contains { model in
            switch state(of: model) {
            case .installed, .ready, .loading: return true
            default: return false
            }
        }
    }

    /// Myna can keep composing while locked when Apple Intelligence is on.
    var canComposeInBackground: Bool { AppleIntelligenceEngine.isAvailable }

    /// Characters of transcript to feed the active model per pass.
    var promptCharacterBudget: Int {
        switch activeModel?.backend {
        case .appleFoundation: return AppleIntelligenceEngine.promptCharacterBudget / 2
        case .coreAI: return CoreAIEngine.promptCharacterBudget
        default: return 6_000
        }
    }

    var activeModel: CatalogModel? { ModelCatalog.model(withID: activeModelID) }

    func state(of model: CatalogModel) -> ModelState {
        states[model.id] ?? .notInstalled
    }

    func refreshInstalledStates() {
        for model in ModelCatalog.all {
            if model.backend == .appleFoundation {
                states[model.id] = AppleIntelligenceEngine.isAvailable
                    ? .ready
                    : .failed(AppleIntelligenceEngine.unavailableReason ?? "Unavailable")
            } else if loadedModelID == model.id {
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

    private var coreAIRoot: URL { modelsRoot.appendingPathComponent("coreai", isDirectory: true) }

    private func directory(for model: CatalogModel) -> URL {
        if model.backend == .coreAI { return coreAIRoot.appendingPathComponent(model.coreAISlug, isDirectory: true) }
        return configuration(for: model).modelDirectory(hub: hub)
    }

    private func isInstalled(_ model: CatalogModel) -> Bool {
        if model.backend == .coreAI {
            let marker = directory(for: model).appendingPathComponent("\(model.coreAISlug).aimodel")
            return FileManager.default.fileExists(atPath: marker.path)
        }
        return FileManager.default.fileExists(atPath: directory(for: model).appendingPathComponent("config.json").path)
    }

    // MARK: - Core AI models (Neural Engine)

    private static let coreAIReleaseBase = "https://github.com/Coral-coder/Myna/releases/download/llm-models"

    private struct CoreAIManifest: Decodable {
        let parts: [String]
        let bytes: Int64
    }

    /// Fetch a Core AI export from this repo's `llm-models` release: a manifest
    /// naming the zip's parts (GitHub caps a file at 2 GB), the parts
    /// themselves, then unzip into place.
    private func downloadCoreAI(_ model: CatalogModel) async throws {
        let slug = model.coreAISlug
        guard let manifestURL = URL(string: "\(Self.coreAIReleaseBase)/\(slug).json") else { throw MynaModelError.noModelInstalled }
        let (manifestData, manifestResponse) = try await URLSession.shared.data(from: manifestURL)
        if let http = manifestResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CoreAIDownloadError.notPublished
        }
        let manifest = try JSONDecoder().decode(CoreAIManifest.self, from: manifestData)
        let total = Double(max(1, manifest.bytes))

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("coreai-\(slug)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = work.appendingPathComponent("\(slug).zip")
        FileManager.default.createFile(atPath: zip.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zip)
        let id = model.id
        coreAIBytes[id] = 0
        for name in manifest.parts {
            guard let url = URL(string: "\(Self.coreAIReleaseBase)/\(name)") else { continue }
            let part = work.appendingPathComponent(name)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let delegate = LabDownloadDelegate(destination: part, progress: { [weak self] bytes in
                    Task { @MainActor in
                        guard let self else { return }
                        self.coreAIBytes[id, default: 0] += bytes
                        self.states[id] = .downloading(min(0.99, Double(self.coreAIBytes[id] ?? 0) / total))
                    }
                }, continuation: continuation)
                URLSession(configuration: .default, delegate: delegate, delegateQueue: nil).downloadTask(with: url).resume()
            }
            // Append this part to the zip in chunks (parts are up to ~2 GB).
            let reader = try FileHandle(forReadingFrom: part)
            while let chunk = try reader.read(upToCount: 8 * 1_048_576), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try reader.close()
            try? FileManager.default.removeItem(at: part)
        }
        try handle.close()

        try FileManager.default.createDirectory(at: coreAIRoot, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: directory(for: model))
        try FileManager.default.unzipItem(at: zip, to: coreAIRoot)
        guard isInstalled(model) else { throw CoreAIDownloadError.incomplete }
    }

    private var coreAIBytes: [String: Int64] = [:]

    enum CoreAIDownloadError: LocalizedError {
        case notPublished
        case incomplete
        var errorDescription: String? {
            switch self {
            case .notPublished: return "This model hasn't been converted and published yet."
            case .incomplete: return "The download was incomplete. Try again."
            }
        }
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
        if model.backend == .appleFoundation {
            refreshInstalledStates()
            if AppleIntelligenceEngine.isAvailable { activeModelID = model.id }
            return
        }
        switch state(of: model) {
        case .downloading, .loading:
            return
        default:
            break
        }
        if model.backend == .coreAI {
            if isInstalled(model) {
                activeModelID = model.id
                refreshInstalledStates()
                return
            }
            states[model.id] = .downloading(0)
            Task {
                do {
                    try await self.downloadCoreAI(model)
                    self.activeModelID = model.id
                    self.refreshInstalledStates()
                } catch {
                    self.states[model.id] = .failed(error.localizedDescription)
                }
            }
            return
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
        if model.backend == .coreAI {
            if activeModelID == model.id { Task { await CoreAIEngine.shared.unload() } }
            try? FileManager.default.removeItem(at: directory(for: model))
            refreshInstalledStates()
            return
        }
        guard model.backend == .mlx else { return }
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
        guard let model = activeModel, model.backend == .mlx, isInstalled(model) else {
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
    ///
    /// Works on screen, in the background and with the phone locked. iOS takes
    /// the GPU away from an app that isn't on screen, so:
    ///   - on screen, the MLX model runs on the GPU (fast);
    ///   - off screen, Apple Intelligence answers when it's available, and
    ///     otherwise the same MLX model runs on the CPU (slower, but it runs);
    ///   - if Myna leaves the screen mid-answer, the GPU run is stopped before
    ///     iOS can fail it (which aborts the app) and the request is run again
    ///     on the CPU, so nothing is dropped.
    func respond(instructions: String, prompt: String, maxTokens: Int = 2048) async throws -> String {
        // A Core AI model runs on the Neural Engine, which Myna may use on
        // screen, in the background and locked — no GPU, no hand-over needed.
        if let model = activeModel, model.backend == .coreAI, isInstalled(model) {
            let finalPrompt = model.wantsThinkingDisabled ? prompt + "\n/no_think" : prompt
            do {
                return try await CoreAIEngine.shared.respond(
                    modelFolder: directory(for: model), instructions: instructions, prompt: finalPrompt, maxTokens: maxTokens)
            } catch {
                // Fall through to the other engines rather than lose the request.
                CrashReporter.log("Core AI failed: \(error.localizedDescription)")
            }
        }
        let onScreen = UIApplication.shared.applicationState == .active
        let appleFirst = activeModel?.backend == .appleFoundation
            || (!onScreen && AppleIntelligenceEngine.isAvailable)
            || (!hasMLXModelInstalled && AppleIntelligenceEngine.isAvailable)
            || (activeModel?.backend == .coreAI && AppleIntelligenceEngine.isAvailable)
        if appleFirst {
            do {
                return try await AppleIntelligenceEngine.respond(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
            } catch {
                // Off screen, Apple Intelligence can run out of budget. If the
                // user's own model is installed, carry on with it on the CPU.
                guard hasMLXModelInstalled, activeModel?.backend == .mlx else { throw error }
            }
        }
        guard hasMLXModelInstalled else {
            throw AppleIntelligenceEngine.isAvailable ? MynaModelError.appleIntelligenceUnavailable : MynaModelError.noModelInstalled
        }

        // Ask iOS for time to finish if Myna gets backgrounded part-way.
        let grace = UIApplication.shared.beginBackgroundTask(withName: "myna.generate")
        defer { if grace != .invalid { UIApplication.shared.endBackgroundTask(grace) } }

        // Runs last (after the count drops): off screen, don't keep 1–3 GB of
        // model resident between conversations.
        defer { if UIApplication.shared.applicationState != .active { releaseForBackground() } }
        generating += 1
        defer { generating -= 1 }

        if UIApplication.shared.applicationState == .active {
            if let answer = try await runMLX(instructions: instructions, prompt: prompt, maxTokens: maxTokens, onCPU: false) {
                return answer
            }
            // Stopped because Myna left the screen — fall through to the CPU.
            CrashReporter.log("generation moved to CPU (left the screen)")
        }
        guard let answer = try await runMLX(instructions: instructions, prompt: prompt, maxTokens: maxTokens, onCPU: true) else {
            throw MynaModelError.needsForeground
        }
        return answer
    }

    /// One MLX generation. Returns nil when a GPU run was stopped because Myna
    /// left the screen (the caller then repeats it on the CPU).
    private func runMLX(instructions: String, prompt: String, maxTokens: Int, onCPU: Bool) async throws -> String? {
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.3, topP: 0.9)
        // Qwen 3's chat template honours a /no_think switch; skip the musing.
        let finalPrompt = activeModel?.wantsThinkingDisabled == true ? prompt + "\n/no_think" : prompt

        if onCPU {
            // Every MLX operation created inside this scope (including the
            // model load and the generation task it spawns) runs on the CPU,
            // which iOS allows off screen.
            return try await Device.withDefaultDevice(.cpu) {
                let container = try await self.ensureContainer()
                let session = ChatSession(container, instructions: instructions, generateParameters: parameters)
                return try await session.respond(to: finalPrompt)
            }
        }

        let container = try await ensureContainer()
        let session = ChatSession(container, instructions: instructions, generateParameters: parameters)
        stoppedForBackground = false
        let work = Task { try await session.respond(to: finalPrompt) }
        mlxWork = work
        defer { mlxWork = nil }
        do {
            let answer = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            return stoppedForBackground ? nil : answer
        } catch {
            if stoppedForBackground { return nil }
            throw error
        }
    }

    private var mlxWork: Task<String, Error>?
    private var stoppedForBackground = false

    /// Myna is leaving the screen: stop any GPU generation now, before iOS
    /// takes the GPU away. `respond` then repeats it on the CPU.
    func stopGenerationForBackground() {
        guard let mlxWork else { return }
        stoppedForBackground = true
        mlxWork.cancel()
    }

    /// MLX generations in flight; the model is only released when idle.
    private var generating = 0

    /// Free the loaded MLX model (often 1–3 GB) when Myna goes to the
    /// background. Background apps get a much smaller memory limit, and keeping
    /// it resident while recording got Myna killed. It reloads on next use.
    func releaseForBackground() {
        guard generating == 0, container != nil else { return }
        container = nil
        loadedModelID = nil
        refreshInstalledStates()
    }

    private var hasMLXModelInstalled: Bool {
        ModelCatalog.all.contains { $0.backend == .mlx && isInstalled($0) }
    }
}

enum MynaModelError: LocalizedError {
    case noModelInstalled
    case needsForeground
    case appleIntelligenceUnavailable

    var errorDescription: String? {
        switch self {
        case .noModelInstalled:
            return "No AI model is installed yet. Visit the Neural Core to download one."
        case .needsForeground:
            return "The on-device model needs Myna on screen to run."
        case .appleIntelligenceUnavailable:
            return AppleIntelligenceEngine.unavailableReason ?? "Apple Intelligence isn't available."
        }
    }
}
