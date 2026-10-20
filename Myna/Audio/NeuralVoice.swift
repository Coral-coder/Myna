import AVFoundation
import Foundation
import SherpaOnnx
import ZIPFoundation

/// A downloadable on-device neural voice (MIT-licensed Piper), hosted as a zip in
/// this repo's `voice-models` release — the BlahBlah approach.
struct NeuralVoiceModel: Identifiable, Equatable {
    let id: String
    let name: String
    let mb: Int
    let modelFile: String
    let tokensFile: String
    let dataDir: String
    let sid: Int
    let speed: Float
}

enum NeuralVoiceCatalog {
    static let releaseBase = "https://github.com/Coral-coder/Myna/releases/download/voice-models"

    /// Piper "hfc" English voices — genuinely MIT-licensed, good quality.
    static let all: [NeuralVoiceModel] = [
        NeuralVoiceModel(id: "en_US-hfc_female-medium", name: "Ava — natural (MIT)", mb: 64,
                         modelFile: "model.onnx", tokensFile: "tokens.txt", dataDir: "espeak-ng-data", sid: 0, speed: 1.0),
        NeuralVoiceModel(id: "en_US-hfc_male-medium", name: "Liam — natural (MIT)", mb: 64,
                         modelFile: "model.onnx", tokensFile: "tokens.txt", dataDir: "espeak-ng-data", sid: 0, speed: 1.0),
    ]

    static func model(id: String) -> NeuralVoiceModel? { all.first { $0.id == id } }
}

/// Downloads/caches the MIT neural voice packs and runs sherpa-onnx TTS on them,
/// fully on-device. Synthesis itself runs off the main actor on `NeuralTTSEngine`.
@MainActor
final class NeuralVoice: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var installed: Set<String> = []

    static let selectedKey = "myna.neuralVoiceID"

    /// The chosen neural voice id, or "" to use Apple's voices instead.
    var selectedID: String { UserDefaults.standard.string(forKey: Self.selectedKey) ?? "" }
    func setSelected(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
        objectWillChange.send()
    }

    /// True when Myna should speak with a neural voice (one is chosen and installed).
    var isActive: Bool { !selectedID.isEmpty && installed.contains(selectedID) }

    let models = NeuralVoiceCatalog.all
    private let root: URL
    private let engine = NeuralTTSEngine()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = support.appendingPathComponent("MynaVoices", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var noBackup = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? noBackup.setResourceValues(values)
        scanInstalled()
    }

    func modelDir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func isInstalled(_ id: String) -> Bool { installed.contains(id) }
    func status(of id: String) -> Status { status[id] ?? (installed.contains(id) ? .ready : .idle) }

    private func scanInstalled() {
        for model in models where FileManager.default.fileExists(atPath: modelDir(model.id).appendingPathComponent(model.modelFile).path) {
            installed.insert(model.id)
        }
    }

    /// Download + unzip a voice pack into the on-device cache.
    func download(_ model: NeuralVoiceModel) {
        if case .downloading = status(of: model.id) { return }
        status[model.id] = .downloading(0)
        Task { await perform(model) }
    }

    private func perform(_ model: NeuralVoiceModel) async {
        guard let url = URL(string: "\(NeuralVoiceCatalog.releaseBase)/\(model.id).zip") else {
            status[model.id] = .failed("Bad voice URL.")
            return
        }
        do {
            let (tmp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                status[model.id] = .failed("Download failed (HTTP \(http.statusCode)).")
                return
            }
            let dir = modelDir(model.id)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: tmp, to: dir)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(model.modelFile).path) {
                installed.insert(model.id)
                status[model.id] = .ready
                if selectedID.isEmpty { setSelected(model.id) }
            } else {
                status[model.id] = .failed("Voice pack was incomplete.")
            }
        } catch {
            status[model.id] = .failed(error.localizedDescription)
        }
    }

    func remove(_ id: String) {
        installed.remove(id)
        status[id] = .idle
        if selectedID == id { setSelected("") }
        try? FileManager.default.removeItem(at: modelDir(id))
    }

    /// Synthesize `text` with the selected installed neural voice → a WAV file
    /// URL to play, or nil (caller falls back to the system voice).
    func synthesize(_ text: String) async -> URL? {
        let id = selectedID
        guard !id.isEmpty, installed.contains(id), let model = NeuralVoiceCatalog.model(id: id) else { return nil }
        return await engine.synthesize(text: text, dir: modelDir(id), model: model)
    }
}

/// Holds the sherpa-onnx offline-TTS pipeline and runs synthesis off the main
/// actor. Loads a model directory once and reuses it.
actor NeuralTTSEngine {
    private var tts: SherpaOnnxOfflineTtsWrapper?
    private var loadedDir: String?

    func synthesize(text: String, dir: URL, model: NeuralVoiceModel) -> URL? {
        if loadedDir != dir.path || tts == nil {
            let vits = sherpaOnnxOfflineTtsVitsModelConfig(
                model: dir.appendingPathComponent(model.modelFile).path,
                lexicon: "",
                tokens: dir.appendingPathComponent(model.tokensFile).path,
                dataDir: dir.appendingPathComponent(model.dataDir).path,
                noiseScale: 0.667,
                noiseScaleW: 0.8,
                lengthScale: 1.0
            )
            let modelConfig = sherpaOnnxOfflineTtsModelConfig(vits: vits, numThreads: 2, debug: 0, provider: "cpu")
            var config = sherpaOnnxOfflineTtsConfig(model: modelConfig)
            tts = SherpaOnnxOfflineTtsWrapper(config: &config)
            loadedDir = dir.path
        }
        guard let tts else { return nil }
        let audio = tts.generate(text: text, sid: model.sid, speed: model.speed)
        guard audio.n > 0 else { return nil }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("myna-tts-\(UUID().uuidString).wav")
        guard audio.save(filename: wav.path) == 1 else { return nil }
        return wav
    }
}
