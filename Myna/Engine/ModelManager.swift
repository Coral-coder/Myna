import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import SwiftUI
import UIKit

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

        // By default an error inside MLX ends the whole app (build 98 crashed
        // this way). Record it instead; `runMLX` turns it into an ordinary
        // failure the caller can handle.
        setErrorHandler({ message, _ in
            CrashReporter.log("MLX error: " + (message.map { String(cString: $0) } ?? "unknown"))
        })

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
        activeModel?.backend == .appleFoundation ? AppleIntelligenceEngine.promptCharacterBudget / 2 : 6_000
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
        // The home computer first, when it's paired and answering. Any failure
        // falls through to this iPhone's own models, so nothing is lost.
        if HomeServer.shared.shouldTry {
            if let answer = try? await HomeServer.shared.generate(instructions: instructions, prompt: prompt, maxTokens: maxTokens) {
                return answer
            }
        }
        // "Don't use this iPhone": leave writing for the home server. The
        // caller keeps the work queued and it is done when the server is back.
        if UserDefaults.standard.bool(forKey: TranscriptionLab.serverOnlyKey),
           HomeServer.shared.isPaired, HomeServer.shared.enabled {
            throw MynaModelError.waitingForServer
        }
        HomeServer.shared.noteLocal("writing")
        let onScreen = UIApplication.shared.applicationState == .active
        let appleFirst = activeModel?.backend == .appleFoundation
            || (!onScreen && AppleIntelligenceEngine.isAvailable)
            || (!hasMLXModelInstalled && AppleIntelligenceEngine.isAvailable)
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

        // Always on the CPU. A graphics-chip run can't be stopped part-way
        // through a step, and if Myna leaves the screen during one (build 88:
        // switching to the browser to sign in) iOS fails it and MLX aborts the
        // whole app. The CPU is slower but is allowed everywhere.
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
            // One generation at a time. Notes, the transcript sorter, chiming
            // in and Ask can all want the model at once, and MLX can't run two
            // generations on one model together.
            await acquireMLX()
            defer { releaseMLX() }
            // Every MLX operation created inside this scope (including the
            // model load and the generation task it spawns) runs on the CPU,
            // which iOS allows off screen. An MLX error inside it is thrown
            // as an ordinary error rather than ending the app.
            return try await withError {
                try await Device.withDefaultDevice(.cpu) {
                    let container = try await self.ensureContainer()
                    let session = ChatSession(container, instructions: instructions, generateParameters: parameters)
                    return try await session.respond(to: finalPrompt)
                }
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

    private var mlxBusy = false
    private var mlxWaiters: [CheckedContinuation<Void, Never>] = []

    /// Wait for the model to be free, then take it.
    private func acquireMLX() async {
        if !mlxBusy {
            mlxBusy = true
            return
        }
        await withCheckedContinuation { mlxWaiters.append($0) }
    }

    /// Hand the model to the next waiter, or mark it free.
    private func releaseMLX() {
        if mlxWaiters.isEmpty {
            mlxBusy = false
        } else {
            mlxWaiters.removeFirst().resume()
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
    case waitingForServer
    case appleIntelligenceUnavailable

    var errorDescription: String? {
        switch self {
        case .noModelInstalled:
            return "No AI model is installed yet. Visit the Neural Core to download one."
        case .waitingForServer:
            return "Waiting for the home server (this iPhone is set not to do the work itself)."
        case .needsForeground:
            return "The on-device model needs Myna on screen to run."
        case .appleIntelligenceUnavailable:
            return AppleIntelligenceEngine.unavailableReason ?? "Apple Intelligence isn't available."
        }
    }
}
