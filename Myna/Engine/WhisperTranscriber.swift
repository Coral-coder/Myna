import Foundation
import SwiftUI
import WhisperKit

/// Downloads, loads and runs OpenAI Whisper locally via WhisperKit.
///
/// Transcription runs on the Apple Neural Engine and never touches the network
/// (the only network use is the one-time model download from Hugging Face).
/// Calls to `transcribe` are serialized by an internal actor so utterances are
/// processed one at a time on a single loaded model.
@MainActor
final class WhisperTranscriber: ObservableObject {

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var loadedModelID: String?
    @Published private(set) var isTranscribing = false
    @AppStorage("myna.whisperModelID") var activeModelID: String = WhisperCatalog.recommendedID
    /// User preference; nil means auto-detect language, otherwise a Whisper code like "en".
    @AppStorage("myna.whisperLanguage") var languageCode: String = "en"

    private let runner = WhisperRunner()
    private let modelsRoot: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsRoot = support.appendingPathComponent("MynaWhisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        // Re-downloadable weights don't belong in iCloud backups.
        var url = modelsRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        refreshInstalledStates()
    }

    // MARK: - State

    var activeModel: WhisperModel? { WhisperCatalog.model(withID: activeModelID) }

    var hasReadyModel: Bool { loadedModelID != nil }

    var hasAnyModelInstalled: Bool {
        WhisperCatalog.all.contains { isInstalled($0) }
    }

    func state(of model: WhisperModel) -> State {
        if loadedModelID == model.id { return .ready }
        if case .downloading(let p) = states[model.id] { return .downloading(p) }
        if case .loading = states[model.id] { return .loading }
        if case .failed(let m) = states[model.id] { return .failed(m) }
        return isInstalled(model) ? .ready : .notInstalled
    }

    private func storedFolderKey(_ variant: String) -> String { "myna.whisper.folder.\(variant)" }

    private func storedFolder(_ variant: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: storedFolderKey(variant)) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func isInstalled(_ model: WhisperModel) -> Bool {
        guard let folder = storedFolder(model.variant) else { return false }
        return FileManager.default.fileExists(atPath: folder.path)
    }

    func refreshInstalledStates() {
        for model in WhisperCatalog.all {
            if loadedModelID == model.id {
                states[model.id] = .ready
            } else if case .downloading = states[model.id] {
                // leave in-flight downloads alone
            } else {
                states[model.id] = isInstalled(model) ? .ready : .notInstalled
            }
        }
    }

    func sizeOnDisk(of model: WhisperModel) -> Int64 {
        guard let folder = storedFolder(model.variant),
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    var totalBytesOnDisk: Int64 {
        WhisperCatalog.all.reduce(0) { $0 + sizeOnDisk(of: $1) }
    }

    // MARK: - Download / load

    /// Downloads (if needed) and loads the model, making it the active transcriber.
    func downloadAndLoad(_ model: WhisperModel) {
        if case .downloading = states[model.id] { return }
        if case .loading = states[model.id] { return }
        states[model.id] = isInstalled(model) ? .loading : .downloading(0)

        Task {
            do {
                let folder: URL
                if let existing = storedFolder(model.variant),
                   FileManager.default.fileExists(atPath: existing.path) {
                    folder = existing
                } else {
                    folder = try await WhisperKit.download(
                        variant: model.variant,
                        downloadBase: modelsRoot,
                        from: "argmaxinc/whisperkit-coreml"
                    ) { progress in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if case .downloading = self.states[model.id] {
                                self.states[model.id] = .downloading(progress.fractionCompleted)
                            }
                        }
                    }
                    UserDefaults.standard.set(folder.path, forKey: storedFolderKey(model.variant))
                }

                states[model.id] = .loading
                try await runner.load(modelFolder: folder.path)
                loadedModelID = model.id
                activeModelID = model.id
                refreshInstalledStates()
            } catch {
                states[model.id] = .failed(error.localizedDescription)
            }
        }
    }

    func delete(_ model: WhisperModel) {
        if loadedModelID == model.id {
            loadedModelID = nil
            Task { await runner.unload() }
        }
        if let folder = storedFolder(model.variant) {
            try? FileManager.default.removeItem(at: folder)
        }
        UserDefaults.standard.removeObject(forKey: storedFolderKey(model.variant))
        refreshInstalledStates()
    }

    /// Ensures the active model is loaded (loading from disk if necessary).
    private func ensureLoaded() async throws {
        if loadedModelID == activeModelID, await runner.isLoaded { return }
        guard let model = activeModel, isInstalled(model), let folder = storedFolder(model.variant) else {
            throw TranscriberError.noModelInstalled
        }
        states[model.id] = .loading
        try await runner.load(modelFolder: folder.path)
        loadedModelID = model.id
        refreshInstalledStates()
    }

    // MARK: - Transcription

    /// Transcribes 16 kHz mono samples to text. Returns "" for silence/noise.
    func transcribe(_ samples: [Float]) async -> String {
        do {
            try await ensureLoaded()
        } catch {
            return ""
        }
        isTranscribing = true
        defer { isTranscribing = false }
        let language = languageCode.isEmpty ? nil : languageCode
        let text = (try? await runner.transcribe(samples, language: language)) ?? ""
        return Self.clean(text)
    }

    /// Whisper emits bracketed non-speech tags like "[BLANK_AUDIO]" — strip them.
    private static func clean(_ text: String) -> String {
        var result = text
        for tag in ["[BLANK_AUDIO]", "[ Silence ]", "(silence)", "[MUSIC]", "[music]", "[Music]"] {
            result = result.replacingOccurrences(of: tag, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: LocalizedError {
    case noModelInstalled
    var errorDescription: String? {
        switch self {
        case .noModelInstalled:
            return "No Whisper model is installed. Download one from the Neural Core."
        }
    }
}

/// Owns the single `WhisperKit` instance and serializes access.
private actor WhisperRunner {
    private var whisperKit: WhisperKit?

    var isLoaded: Bool { whisperKit != nil }

    func load(modelFolder: String) async throws {
        let config = WhisperKitConfig(
            modelFolder: modelFolder,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
    }

    func unload() async {
        if let whisperKit {
            await whisperKit.unloadModels()
        }
        whisperKit = nil
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let whisperKit else { throw TranscriberError.noModelInstalled }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0.0,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}
