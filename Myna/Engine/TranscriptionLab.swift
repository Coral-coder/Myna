import AVFoundation
import CoreML
import Foundation
import Security
import SherpaOnnx
import Speech
import SwiftData
import WhisperKit

// The Transcription Lab: record one clip from the bracelet, run it through every
// speech-to-text engine, and compare the text and the time each one took — on
// identical audio, so the ranking is fair.

/// One engine the lab can run.
struct LabEngine: Identifiable, Equatable {
    enum Kind: Equatable {
        case appleLegacy
        case appleTranscriber
        case appleDictation
        case whisperKit(model: String)
        case sherpa(SherpaSpec)
        case cloud(CloudVendor)
    }

    let id: String
    let name: String
    let detail: String
    /// Approximate download size; 0 when there is nothing to download.
    let megabytes: Int
    let kind: Kind

    var isCloud: Bool { if case .cloud = kind { return true }; return false }
}

/// A sherpa-onnx model: where its files live on Hugging Face and how to wire them.
struct SherpaSpec: Equatable {
    enum Family: Equatable { case nemoTransducer, zipformer, moonshine, senseVoice, whisper, canary }
    let family: Family
    let repo: String
    /// Files to download, in the role order the family expects (see `LabSherpa`).
    let files: [String]
    /// Longest stretch of audio fed to the model in one go.
    let chunkSeconds: Double
}

enum CloudVendor: String, CaseIterable, Equatable {
    case deepgram, openai, groq, elevenlabs, mistral, assemblyai, soniox, speechmatics

    var label: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        case .elevenlabs: return "ElevenLabs"
        case .mistral: return "Mistral"
        case .assemblyai: return "AssemblyAI"
        case .soniox: return "Soniox"
        case .speechmatics: return "Speechmatics"
        }
    }
}

enum LabCatalog {
    static let all: [LabEngine] = onDevice + cloud

    static let onDevice: [LabEngine] = [
        LabEngine(id: "apple-legacy", name: "Apple Speech (current)", detail: "What Myna uses live today. On device.", megabytes: 0, kind: .appleLegacy),
        LabEngine(id: "apple-transcriber", name: "Apple SpeechTranscriber", detail: "Apple's new iOS 26 model. On device; iOS manages the model. Omi's iOS fallback.", megabytes: 0, kind: .appleTranscriber),
        LabEngine(id: "apple-dictation", name: "Apple DictationTranscriber", detail: "iOS 26 dictation model, long-form preset. On device.", megabytes: 0, kind: .appleDictation),

        LabEngine(id: "wk-tiny", name: "Whisper tiny.en", detail: "WhisperKit, Neural Engine.", megabytes: 153, kind: .whisperKit(model: "tiny.en")),
        LabEngine(id: "wk-base", name: "Whisper base.en", detail: "WhisperKit. What Myna's notes use today.", megabytes: 147, kind: .whisperKit(model: "base.en")),
        LabEngine(id: "wk-small", name: "Whisper small.en", detail: "WhisperKit, compressed.", megabytes: 218, kind: .whisperKit(model: "small.en_217MB")),
        LabEngine(id: "wk-distil", name: "Distil-Whisper large-v3", detail: "WhisperKit, compressed.", megabytes: 595, kind: .whisperKit(model: "distil-large-v3_594MB")),
        LabEngine(id: "wk-turbo", name: "Whisper large-v3 turbo", detail: "WhisperKit, compressed. Their recommended model.", megabytes: 627, kind: .whisperKit(model: "large-v3-v20240930_626MB")),

        LabEngine(id: "sh-parakeet-v2", name: "Parakeet TDT 0.6b v2", detail: "NVIDIA, English. The model Omi runs on device.", megabytes: 661,
                  kind: .sherpa(SherpaSpec(family: .nemoTransducer, repo: "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
                                           files: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"], chunkSeconds: 24))),
        LabEngine(id: "sh-parakeet-v3", name: "Parakeet TDT 0.6b v3", detail: "NVIDIA, 25 languages. The model Omi's servers run for recordings.", megabytes: 671,
                  kind: .sherpa(SherpaSpec(family: .nemoTransducer, repo: "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
                                           files: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"], chunkSeconds: 24))),
        LabEngine(id: "sh-parakeet-ultra", name: "Parakeet TDT 0.6b ultra", detail: "A newer post-training of v3.", megabytes: 671,
                  kind: .sherpa(SherpaSpec(family: .nemoTransducer, repo: "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-ultra-int8",
                                           files: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"], chunkSeconds: 24))),
        LabEngine(id: "sh-moonshine-tiny", name: "Moonshine tiny", detail: "Built for small devices. English.", megabytes: 124,
                  kind: .sherpa(SherpaSpec(family: .moonshine, repo: "csukuangfj/sherpa-onnx-moonshine-tiny-en-int8",
                                           files: ["preprocess.onnx", "encode.int8.onnx", "uncached_decode.int8.onnx", "cached_decode.int8.onnx", "tokens.txt"], chunkSeconds: 12))),
        LabEngine(id: "sh-moonshine-base", name: "Moonshine base", detail: "Built for small devices. English.", megabytes: 287,
                  kind: .sherpa(SherpaSpec(family: .moonshine, repo: "csukuangfj/sherpa-onnx-moonshine-base-en-int8",
                                           files: ["preprocess.onnx", "encode.int8.onnx", "uncached_decode.int8.onnx", "cached_decode.int8.onnx", "tokens.txt"], chunkSeconds: 12))),
        LabEngine(id: "sh-sensevoice", name: "SenseVoice small", detail: "Alibaba. Very fast; English, Chinese, Japanese, Korean.", megabytes: 229,
                  kind: .sherpa(SherpaSpec(family: .senseVoice, repo: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
                                           files: ["model.int8.onnx", "tokens.txt"], chunkSeconds: 24))),
        LabEngine(id: "sh-canary", name: "Canary 180m flash", detail: "NVIDIA. English, Spanish, German, French.", megabytes: 198,
                  kind: .sherpa(SherpaSpec(family: .canary, repo: "csukuangfj/sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8",
                                           files: ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"], chunkSeconds: 24))),
        LabEngine(id: "sh-zipformer", name: "Zipformer (Libriheavy)", detail: "Next-gen Kaldi, with punctuation and case. Very small.", megabytes: 67,
                  kind: .sherpa(SherpaSpec(family: .zipformer, repo: "csukuangfj/sherpa-onnx-zipformer-en-libriheavy-20230830-medium-punct-case",
                                           files: ["encoder-epoch-50-avg-15.int8.onnx", "decoder-epoch-50-avg-15.int8.onnx", "joiner-epoch-50-avg-15.int8.onnx", "tokens.txt"], chunkSeconds: 24))),
        LabEngine(id: "sh-distil-small", name: "Distil-Whisper small.en (ONNX)", detail: "Whisper on the CPU runtime, for comparison with WhisperKit.", megabytes: 285,
                  kind: .sherpa(SherpaSpec(family: .whisper, repo: "csukuangfj/sherpa-onnx-whisper-distil-small.en",
                                           files: ["distil-small.en-encoder.int8.onnx", "distil-small.en-decoder.int8.onnx", "distil-small.en-tokens.txt"], chunkSeconds: 28))),
    ]

    static let cloud: [LabEngine] = [
        LabEngine(id: "c-soniox", name: "Soniox stt-async-v6", detail: "Omi's cloud default family. Audio leaves the phone.", megabytes: 0, kind: .cloud(.soniox)),
        LabEngine(id: "c-deepgram", name: "Deepgram Nova-3", detail: "Omi's former default. Audio leaves the phone.", megabytes: 0, kind: .cloud(.deepgram)),
        LabEngine(id: "c-openai", name: "OpenAI gpt-transcribe", detail: "Audio leaves the phone.", megabytes: 0, kind: .cloud(.openai)),
        LabEngine(id: "c-groq", name: "Groq Whisper large-v3 turbo", detail: "Audio leaves the phone.", megabytes: 0, kind: .cloud(.groq)),
        LabEngine(id: "c-elevenlabs", name: "ElevenLabs Scribe v2", detail: "Audio leaves the phone.", megabytes: 0, kind: .cloud(.elevenlabs)),
        LabEngine(id: "c-mistral", name: "Mistral Voxtral mini", detail: "Audio leaves the phone.", megabytes: 0, kind: .cloud(.mistral)),
        LabEngine(id: "c-assemblyai", name: "AssemblyAI", detail: "Audio leaves the phone.", megabytes: 0, kind: .cloud(.assemblyai)),
        LabEngine(id: "c-speechmatics", name: "Speechmatics enhanced", detail: "Audio leaves the phone.", megabytes: 0, kind: .cloud(.speechmatics)),
    ]
}

struct LabError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Stores the cloud API keys the user types into the lab. Keychain only.
enum LabKeychain {
    private static let service = "com.lightwave.myna.lab"

    static func get(_ vendor: CloudVendor) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func set(_ value: String, for vendor: CloudVendor) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Downloads one file with byte-level progress.
private final class LabDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void, continuation: CheckedContinuation<Void, Error>) {
        self.destination = destination
        self.progress = progress
        self.continuation = continuation
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(bytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(LabError("Download failed (HTTP \(http.statusCode)).")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
    }
}

@MainActor
final class TranscriptionLab: ObservableObject {
    static let shared = TranscriptionLab()

    struct Outcome: Equatable {
        var text: String = ""
        var seconds: Double = 0
        var error: String?
    }

    enum Activity: Equatable {
        case idle
        case downloading(Double)
        case running
    }

    @Published private(set) var isRecording = false
    @Published private(set) var clipSeconds: Double = 0
    @Published private(set) var activity: [String: Activity] = [:]
    @Published private(set) var outcomes: [String: Outcome] = [:]
    @Published private(set) var installed: Set<String> = []
    /// The user's own 1–5 score per engine, kept across launches.
    @Published var ratings: [String: Int] = [:] {
        didSet { UserDefaults.standard.set(ratings, forKey: Self.ratingsKey) }
    }

    private static let ratingsKey = "myna.lab.ratings"
    static let maxClipSeconds: Double = 120

    private var samples: [Float] = []
    private var sampleRate: Double = 16_000
    private let root: URL
    private weak var recordingListener: SpeechListener?
    private var downloadedBytes: [String: Int64] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = support.appendingPathComponent("MynaLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var noBackup = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? noBackup.setResourceValues(values)
        ratings = (UserDefaults.standard.dictionary(forKey: Self.ratingsKey) as? [String: Int]) ?? [:]
        loadClip()
        scanInstalled()
    }

    // MARK: - Clip

    private var clipURL: URL { root.appendingPathComponent("clip.wav") }
    var hasClip: Bool { !samples.isEmpty }

    /// Start capturing whatever the bracelet sends, until stopped or the cap.
    func startRecording(from listener: SpeechListener) {
        guard !isRecording else { return }
        samples.removeAll()
        clipSeconds = 0
        outcomes.removeAll()
        isRecording = true
        recordingListener = listener
        listener.externalAudioSink = { [weak self] buffer in
            self?.append(buffer)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingListener?.externalAudioSink = nil
        recordingListener = nil
        saveClip()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        sampleRate = buffer.format.sampleRate
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: frames))
        clipSeconds = Double(samples.count) / sampleRate
        if clipSeconds >= Self.maxClipSeconds { stopRecording() }
    }

    private func saveClip() {
        guard !samples.isEmpty else { return }
        try? LabWav.data(samples: samples, sampleRate: Int(sampleRate)).write(to: clipURL, options: .atomic)
    }

    private func loadClip() {
        guard let file = try? AVAudioFile(forReading: clipURL) else { return }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0] else { return }
        samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        sampleRate = format.sampleRate
        clipSeconds = Double(samples.count) / sampleRate
    }

    // MARK: - Models

    private func sherpaDir(_ engine: LabEngine) -> URL { root.appendingPathComponent(engine.id, isDirectory: true) }

    private func scanInstalled() {
        var found: Set<String> = []
        for engine in LabCatalog.all {
            switch engine.kind {
            case .sherpa(let spec):
                let dir = sherpaDir(engine)
                if spec.files.allSatisfy({ Self.fileSize(dir.appendingPathComponent($0)) > 0 }) { found.insert(engine.id) }
            case .whisperKit:
                if UserDefaults.standard.bool(forKey: "myna.lab.wk.\(engine.id)") { found.insert(engine.id) }
            default:
                found.insert(engine.id)
            }
        }
        installed = found
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func isReady(_ engine: LabEngine) -> Bool {
        if case .cloud(let vendor) = engine.kind { return !LabKeychain.get(vendor).isEmpty }
        return installed.contains(engine.id)
    }

    func activity(of engine: LabEngine) -> Activity { activity[engine.id] ?? .idle }

    /// Fetch an engine's model. Apple and cloud engines have nothing to fetch.
    func download(_ engine: LabEngine) {
        guard activity(of: engine) == .idle else { return }
        activity[engine.id] = .downloading(0)
        Task {
            do {
                switch engine.kind {
                case .sherpa(let spec):
                    try await downloadSherpa(engine, spec)
                case .whisperKit(let model):
                    // WhisperKit fetches into its own cache on first load.
                    _ = try await WhisperKit(WhisperKitConfig(model: model, computeOptions: Self.whisperCompute))
                    UserDefaults.standard.set(true, forKey: "myna.lab.wk.\(engine.id)")
                default:
                    break
                }
                installed.insert(engine.id)
                activity[engine.id] = .idle
                if engine.id == activeEngineID { applyActiveEngine() }
            } catch {
                activity[engine.id] = .idle
                outcomes[engine.id] = Outcome(error: "Download failed: \(error.localizedDescription)")
            }
        }
    }

    private func downloadSherpa(_ engine: LabEngine, _ spec: SherpaSpec) async throws {
        let dir = sherpaDir(engine)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = Double(max(1, engine.megabytes)) * 1_048_576
        let id = engine.id
        downloadedBytes[id] = 0
        for name in spec.files {
            let dest = dir.appendingPathComponent(name)
            if Self.fileSize(dest) > 0 { downloadedBytes[id, default: 0] += Self.fileSize(dest); continue }
            guard let url = URL(string: "https://huggingface.co/\(spec.repo)/resolve/main/\(name)") else {
                throw LabError("Bad model URL.")
            }
            let part = dir.appendingPathComponent(name + ".part")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let delegate = LabDownloadDelegate(destination: part, progress: { [weak self] bytes in
                    Task { @MainActor in
                        guard let self else { return }
                        self.downloadedBytes[id, default: 0] += bytes
                        self.activity[id] = .downloading(min(1, Double(self.downloadedBytes[id] ?? 0) / total))
                    }
                }, continuation: continuation)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                session.downloadTask(with: url).resume()
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: part, to: dest)
        }
    }

    func remove(_ engine: LabEngine) {
        if case .sherpa = engine.kind { try? FileManager.default.removeItem(at: sherpaDir(engine)) }
        if case .whisperKit = engine.kind { UserDefaults.standard.removeObject(forKey: "myna.lab.wk.\(engine.id)") }
        installed.remove(engine.id)
        outcomes[engine.id] = nil
        if engine.id == activeEngineID { applyActiveEngine() }
    }

    // MARK: - Running

    private static var whisperCompute: ModelComputeOptions {
        ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
    }

    /// Run every engine that is ready, one after another (they'd fight for the
    /// Neural Engine and memory in parallel, which would skew the timings).
    func runAllReady() {
        Task {
            for engine in LabCatalog.all where isReady(engine) && activity(of: engine) == .idle {
                await run(engine)
            }
        }
    }

    func runOne(_ engine: LabEngine) {
        Task { await run(engine) }
    }

    private func run(_ engine: LabEngine) async {
        guard hasClip, activity(of: engine) == .idle else { return }
        activity[engine.id] = .running
        let started = Date()
        do {
            let text = try await transcribe(engine)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            outcomes[engine.id] = Outcome(text: cleaned.isEmpty ? "(nothing recognized)" : cleaned,
                                          seconds: Date().timeIntervalSince(started), error: nil)
        } catch {
            outcomes[engine.id] = Outcome(text: "", seconds: Date().timeIntervalSince(started), error: error.localizedDescription)
        }
        activity[engine.id] = .idle
    }

    private func transcribe(_ engine: LabEngine) async throws -> String {
        try await LabRunner.shared.transcribe(engine: engine, modelDir: sherpaDir(engine),
                                              samples: samples, sampleRate: Int(sampleRate))
    }

    // MARK: - The engine Myna actually uses

    static let activeKey = "myna.transcriptionEngine"
    /// Apple's word-by-word recognizer: the one engine that streams by itself.
    static let legacyID = "apple-legacy"
    /// Parakeet TDT v2 — the model Omi runs on the phone.
    static let defaultEngineID = "sh-parakeet-v2"
    /// What Omi falls back to on iOS when Parakeet can't run.
    static let fallbackIDs = ["apple-transcriber", "apple-legacy"]

    /// The engine that transcribes bracelet audio. Persisted.
    @Published private(set) var activeEngineID: String = UserDefaults.standard.string(forKey: TranscriptionLab.activeKey) ?? TranscriptionLab.defaultEngineID
    /// What the active engine last did, for the settings screen.
    @Published private(set) var liveStatus: String = ""

    var activeEngine: LabEngine {
        LabCatalog.all.first { $0.id == activeEngineID } ?? LabCatalog.all[0]
    }

    /// The engine that will really run right now: the chosen one if its model is
    /// here, otherwise the first fallback.
    var effectiveEngine: LabEngine {
        let chosen = activeEngine
        if isReady(chosen) { return chosen }
        return LabCatalog.all.first { $0.id == Self.fallbackIDs[0] } ?? chosen
    }

    func setActive(_ engine: LabEngine) {
        activeEngineID = engine.id
        UserDefaults.standard.set(engine.id, forKey: Self.activeKey)
        liveStatus = ""
        applyActiveEngine()
        if !isReady(engine), !engine.isCloud { download(engine) }
    }

    private weak var liveListener: SpeechListener?
    private var container: ModelContainer?

    /// Called once at launch: route bracelet audio to the chosen engine, and
    /// fetch its model (and the voice-print model) if they aren't here yet.
    func attach(listener: SpeechListener, container: ModelContainer) {
        liveListener = listener
        self.container = container
        listener.onDelivered = { [weak self] text in
            // Apple's own recognizer produced this line (no audio to voice-print).
            guard let self, listener.externalTranscriber == nil else { return }
            self.record(text: text, heardAt: .now, duration: 0, engine: "Apple Speech", voicePrint: nil)
        }
        applyActiveEngine()
        let chosen = activeEngine
        if !isReady(chosen), !chosen.isCloud { download(chosen) }
        Task { await VoiceID.shared.prepare() }
        startDrainLoop()
    }

    /// Apple's live recognizer handles the stream itself. Any other engine gets
    /// the bracelet audio here, cut into utterances at pauses.
    private func applyActiveEngine() {
        liveSamples.removeAll()
        liveVoiced = 0
        liveSilence = 0
        if activeEngineID == Self.legacyID {
            liveListener?.externalTranscriber = nil
        } else {
            liveListener?.externalTranscriber = { [weak self] buffer in
                self?.ingestLive(buffer)
            }
        }
    }

    private var liveSamples: [Float] = []
    private var liveRate: Double = 16_000
    private var liveVoiced = 0
    /// Running estimate of the room's background level (see `ingestLive`).
    private var liveNoiseFloor: Float = 0.002
    private var liveSilence = 0
    private var liveQueue: Task<Void, Never>?
    private var livePending = 0

    /// The utterance being spoken right now, as the chosen engine hears it so
    /// far. Refreshed several times a second while someone is talking.
    @Published private(set) var livePartial: String = ""
    private var interimBusy = false
    private var lastInterimCount = 0
    private var liveGeneration = 0

    /// Re-transcribe the utterance-so-far so words show up while they're being
    /// said, not only at the pause. Runs only when the engine is free, so it
    /// can't fall behind or delay the final pass.
    private func refreshLivePartial() {
        let engine = effectiveEngine
        switch engine.kind {
        case .sherpa, .whisperKit: break
        default: return   // Apple's own recognizer already streams; cloud would bill per pass.
        }
        guard !interimBusy, livePending == 0, liveVoiced > 0,
              liveSamples.count - lastInterimCount >= Int(liveRate * 0.5) else { return }
        interimBusy = true
        lastInterimCount = liveSamples.count
        let snapshot = liveSamples
        let rate = Int(liveRate)
        let generation = liveGeneration
        let dir = sherpaDir(engine)
        Task { [weak self] in
            let text = try? await LabRunner.shared.transcribe(engine: engine, modelDir: dir, samples: snapshot, sampleRate: rate)
            guard let self else { return }
            self.interimBusy = false
            guard generation == self.liveGeneration, let text else { return }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { self.livePartial = cleaned }
        }
    }

    /// Collects bracelet audio and hands all of it to the engine, cut where the
    /// speaker pauses (or every 20 s without a pause). Nothing is discarded.
    private func ingestLive(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        liveRate = buffer.format.sampleRate
        var sum: Float = 0
        for i in 0..<frames { sum += data[i] * data[i] }
        let level = (sum / Float(frames)).squareRoot()
        // "Is someone speaking" is judged against the room's own background
        // level, not a fixed loudness: a fixed bar threw away quiet speech from
        // across the room. The background estimate drops quickly to any quieter
        // moment and creeps up slowly, so talk doesn't raise it.
        if level < liveNoiseFloor {
            liveNoiseFloor = liveNoiseFloor * 0.5 + level * 0.5
        } else {
            liveNoiseFloor *= 1.0005
        }
        liveNoiseFloor = min(max(liveNoiseFloor, 0.0002), 0.02)
        let speaking = level > max(0.0012, liveNoiseFloor * 2.2)

        liveSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: frames))
        MusicSpotter.shared.ingest(data, count: frames, sampleRate: liveRate)
        if speaking {
            liveVoiced += frames
            liveSilence = 0
        } else {
            liveSilence += frames
        }

        refreshLivePartial()

        let paused = liveVoiced > 0 && Double(liveSilence) >= liveRate * 0.8
        let tooLong = Double(liveSamples.count) >= liveRate * 20
        guard paused || tooLong else { return }

        let chunk = liveSamples
        let voicedSeconds = Double(liveVoiced) / liveRate
        liveSamples.removeAll(keepingCapacity: true)
        liveVoiced = 0
        liveSilence = 0
        liveGeneration += 1
        lastInterimCount = 0
        // Everything is transcribed, however quiet: the loudness check above
        // only decides where to cut, never what to keep. Whether a stretch
        // holds speech is left to the transcriber itself.
        enqueueLive(chunk, rate: Int(liveRate), voicedSeconds: max(voicedSeconds, 0.1))
    }

    /// Utterances are transcribed strictly in order, one at a time; nothing is
    /// skipped if the engine is slower than the talking. If the chosen engine
    /// fails, the fallbacks are tried on the same audio.
    private func enqueueLive(_ chunk: [Float], rate: Int, voicedSeconds: Double) {
        var candidates = [effectiveEngine]
        for id in Self.fallbackIDs where !candidates.contains(where: { $0.id == id }) {
            if let engine = LabCatalog.all.first(where: { $0.id == id }) { candidates.append(engine) }
        }
        let engines = candidates
        let dirs = engines.map { sherpaDir($0) }
        let seconds = Double(chunk.count) / Double(rate)
        let heardAt = Date().addingTimeInterval(-seconds)
        let previous = liveQueue
        livePending += 1
        liveStatus = "Transcribing with \(engines[0].name)… (\(livePending) waiting)"
        liveQueue = Task { [weak self] in
            await previous?.value
            let started = Date()
            var text = ""
            var usedName = ""
            var lastError = ""
            // The home computer first, when it's paired and answering. If it
            // fails, the same audio falls through to the phone's own engines.
            if HomeServer.shared.shouldTry {
                do {
                    text = try await HomeServer.shared.transcribe(wav: LabWav.data(samples: chunk, sampleRate: rate), audioSeconds: seconds)
                    usedName = "Home server"
                } catch {
                    lastError = "Home server: \(error.localizedDescription)"
                }
            }
            // "Home server only": don't transcribe here. Keep the audio and hand
            // it to the server when it answers again. (If the phone runs out of
            // room for held audio, it transcribes here rather than lose any.)
            if usedName.isEmpty, UserDefaults.standard.bool(forKey: Self.serverOnlyKey),
               let self, self.hold(chunk, rate: rate, heardAt: heardAt, voicedSeconds: voicedSeconds) {
                self.livePending = max(0, self.livePending - 1)
                if self.livePending == 0, self.liveVoiced == 0 { self.livePartial = "" }
                self.liveStatus = "Saved for the home server (\(self.heldCount) waiting)"
                return
            }
            for (index, engine) in engines.enumerated() where usedName.isEmpty {
                do {
                    text = try await LabRunner.shared.transcribe(engine: engine, modelDir: dirs[index], samples: chunk, sampleRate: rate)
                    usedName = engine.name
                    HomeServer.shared.noteLocal("transcription")
                    break
                } catch {
                    lastError = "\(engine.name) failed: \(error.localizedDescription)"
                }
            }
            let voice = await VoiceID.shared.embedding(samples: chunk, sampleRate: rate)
            guard let self else { return }
            self.livePending = max(0, self.livePending - 1)
            // The finished line replaces the in-progress preview of it.
            if self.livePending == 0, self.liveVoiced == 0 { self.livePartial = "" }
            guard !usedName.isEmpty else {
                self.liveStatus = lastError
                return
            }
            let took = Date().timeIntervalSince(started)
            self.liveStatus = String(format: "%@ · %.1f s of audio in %.1f s", usedName, seconds, took)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            self.record(text: cleaned, heardAt: heardAt, duration: voicedSeconds, engine: usedName, voicePrint: voice)
            self.liveListener?.deliverExternalText(cleaned)
        }
    }

    // MARK: - Audio held for the home server

    static let serverOnlyKey = "myna.server.only"
    /// Most audio kept on the phone while the server is away (about 17 hours).
    private static let heldLimitBytes = 2_000_000_000

    /// Clips waiting for the home server.
    @Published private(set) var heldCount = 0
    private var draining = false
    private var drainLoop: Task<Void, Never>?

    private static var heldFolder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("held-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func heldFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: heldFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Keep one clip for later. False if it couldn't be kept (no room left).
    private func hold(_ chunk: [Float], rate: Int, heardAt: Date, voicedSeconds: Double) -> Bool {
        let files = Self.heldFiles()
        let used = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard used < Self.heldLimitBytes else { return false }
        // The name carries when it was heard, so order and time survive.
        let name = String(format: "%015.0f_%d.wav", heardAt.timeIntervalSince1970 * 1000, Int(voicedSeconds * 10))
        do {
            try LabWav.data(samples: chunk, sampleRate: rate).write(to: Self.heldFolder.appendingPathComponent(name), options: .atomic)
        } catch {
            return false
        }
        heldCount = files.count + 1
        return true
    }

    /// Watch for the server coming back and hand it everything that was held.
    private func startDrainLoop() {
        heldCount = Self.heldFiles().count
        guard drainLoop == nil else { return }
        drainLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.drainHeld()
            }
        }
    }

    private func drainHeld() async {
        guard !draining, heldCount > 0, HomeServer.shared.shouldTry, HomeServer.shared.reachable == true else { return }
        draining = true
        defer { draining = false }
        for file in Self.heldFiles() {
            guard let wav = try? Data(contentsOf: file), wav.count > 44 else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "_")
            let heardAt = Date(timeIntervalSince1970: (Double(parts.first ?? "") ?? Date().timeIntervalSince1970 * 1000) / 1000)
            let voiced = (Double(parts.last ?? "") ?? 0) / 10
            // 16-bit mono after a 44-byte header, as LabWav writes it.
            let rate = Int(wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let samples: [Float] = wav.subdata(in: 44..<wav.count).withUnsafeBytes { raw in
                let count = raw.count / 2
                return (0..<count).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32767 }
            }
            let seconds = rate > 0 ? Double(samples.count) / Double(rate) : 0
            guard let text = try? await HomeServer.shared.transcribe(wav: wav, audioSeconds: seconds) else {
                break  // the server went away again; keep the rest for next time
            }
            try? FileManager.default.removeItem(at: file)
            heldCount = max(0, heldCount - 1)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                let voice = await VoiceID.shared.embedding(samples: samples, sampleRate: rate)
                record(text: cleaned, heardAt: heardAt, duration: voiced, engine: "Home server", voicePrint: voice)
            }
            liveStatus = heldCount > 0 ? "Catching up on the home server (\(heldCount) left)" : "Caught up with the home server"
        }
        heldCount = Self.heldFiles().count
    }

    // MARK: - The transcript and the voices in it

    /// How alike two voice prints must be to count as the same person.
    private static let sameVoice: Float = 0.5

    /// Saves one utterance, attributing it to a known voice or starting a new
    /// "Speaker N" when the voice isn't one Myna has heard.
    private func record(text: String, heardAt: Date, duration: Double, engine: String, voicePrint: [Float]?) {
        guard let context = container?.mainContext else { return }
        var speakerKey = ""
        if let voicePrint {
            let people = (try? context.fetch(FetchDescriptor<VoicePerson>())) ?? []
            var best: VoicePerson?
            var bestScore: Float = -1
            for person in people {
                let score = VoicePrint.similarity(VoicePrint.vector(person.centroid), voicePrint)
                if score > bestScore { bestScore = score; best = person }
            }
            if let best, bestScore >= Self.sameVoice {
                best.centroid = VoicePrint.data(VoicePrint.merged(VoicePrint.vector(best.centroid), count: best.sampleCount, with: voicePrint))
                best.sampleCount += 1
                speakerKey = best.key
            } else {
                let person = VoicePerson(name: "Speaker \(people.count + 1)", centroid: VoicePrint.data(voicePrint))
                context.insert(person)
                speakerKey = person.key
            }
        }
        context.insert(Utterance(text: text, heardAt: heardAt, duration: duration, engine: engine,
                                 speakerKey: speakerKey, embedding: voicePrint.map(VoicePrint.data)))
        try? context.save()
    }

    /// "This voice is …": name the person behind an utterance. If someone with
    /// that name already exists, the voice is merged into them.
    func name(_ person: VoicePerson, as rawName: String) {
        guard let context = container?.mainContext else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let people = (try? context.fetch(FetchDescriptor<VoicePerson>())) ?? []
        if let existing = people.first(where: { $0.key != person.key && $0.isNamed && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let oldKey = person.key
            let newKey = existing.key
            let lines = (try? context.fetch(FetchDescriptor<Utterance>(predicate: #Predicate<Utterance> { $0.speakerKey == oldKey }))) ?? []
            for line in lines { line.speakerKey = newKey }
            existing.centroid = VoicePrint.data(VoicePrint.merged(VoicePrint.vector(existing.centroid), count: existing.sampleCount,
                                                                 with: VoicePrint.vector(person.centroid)))
            existing.sampleCount += person.sampleCount
            context.delete(person)
        } else {
            person.name = name
            person.isNamed = true
        }
        try? context.save()
    }

    /// "That wasn't them, it was …": move one utterance to another person and
    /// teach that person's voice print with it.
    func assign(_ utterance: Utterance, to person: VoicePerson) {
        guard let context = container?.mainContext else { return }
        utterance.speakerKey = person.key
        if let data = utterance.embedding {
            person.centroid = VoicePrint.data(VoicePrint.merged(VoicePrint.vector(person.centroid), count: person.sampleCount,
                                                               with: VoicePrint.vector(data)))
            person.sampleCount += 1
        }
        try? context.save()
    }
}

/// Keeps the active engine's model loaded between calls, and runs one
/// transcription at a time.
actor LabRunner {
    static let shared = LabRunner()

    private var sherpaID: String?
    private var sherpa: SherpaOnnxOfflineRecognizer?
    private var whisperID: String?
    private var whisper: WhisperKit?

    func transcribe(engine: LabEngine, modelDir: URL, samples: [Float], sampleRate: Int) async throws -> String {
        switch engine.kind {
        case .sherpa(let spec):
            if sherpaID != engine.id || sherpa == nil {
                sherpa = nil
                sherpa = try LabSherpa.makeRecognizer(spec: spec, dir: modelDir)
                sherpaID = engine.id
            }
            guard let sherpa else { throw LabError("Model didn't load.") }
            return LabSherpa.decode(sherpa, spec: spec, samples: samples, sampleRate: sampleRate)
        case .whisperKit(let model):
            if whisperID != engine.id || whisper == nil {
                whisper = nil
                let compute = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
                whisper = try await WhisperKit(WhisperKitConfig(model: model, computeOptions: compute))
                whisperID = engine.id
            }
            guard let whisper else { throw LabError("Model didn't load.") }
            let url = try LabWav.writeTemp(samples: samples, sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: url) }
            let results = try await whisper.transcribe(audioPath: url.path)
            return results.map(\.text).joined(separator: " ")
        case .appleLegacy, .appleTranscriber, .appleDictation:
            let url = try LabWav.writeTemp(samples: samples, sampleRate: sampleRate)
            defer { try? FileManager.default.removeItem(at: url) }
            if case .appleLegacy = engine.kind { return try await LabApple.legacy(url) }
            if case .appleTranscriber = engine.kind { return try await LabApple.transcriber(url) }
            return try await LabApple.dictation(url)
        case .cloud(let vendor):
            let key = LabKeychain.get(vendor)
            guard !key.isEmpty else { throw LabError("Add an API key first.") }
            return try await LabCloud.transcribe(vendor: vendor, key: key, wav: LabWav.data(samples: samples, sampleRate: sampleRate))
        }
    }
}

/// 16-bit mono WAV — the one format every engine and every cloud API takes.
enum LabWav {
    static func data(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32767).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        let rate = UInt32(sampleRate)
        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: le32(UInt32(36 + pcm.count)))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        wav.append(contentsOf: le32(16))
        wav.append(contentsOf: le16(1))
        wav.append(contentsOf: le16(1))
        wav.append(contentsOf: le32(rate))
        wav.append(contentsOf: le32(rate * 2))
        wav.append(contentsOf: le16(2))
        wav.append(contentsOf: le16(16))
        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: le32(UInt32(pcm.count)))
        wav.append(pcm)
        return wav
    }

    static func writeTemp(samples: [Float], sampleRate: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myna-stt-\(UUID().uuidString).wav")
        try data(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
        return url
    }
}

/// Lets a callback that may fire several times resume a continuation once.
private final class LabOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

// MARK: - Apple engines

enum LabApple {
    private static var locale: Locale { Locale(identifier: Locale.preferredLanguages.first ?? "en-US") }

    /// The recognizer Myna uses live today, run over the file.
    static func legacy(_ url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw LabError("Apple Speech isn't available for this language.")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = LabOnce()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
        }
    }

    /// Apple's iOS 26 long-form model.
    static func transcriber(_ url: URL) async throws -> String {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LabError("SpeechTranscriber isn't available on this device or language.")
        }
        let module = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () throws -> String in
            var text = ""
            for try await result in module.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    /// Apple's iOS 26 dictation model, long-form preset.
    static func dictation(_ url: URL) async throws -> String {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LabError("DictationTranscriber isn't available for this language.")
        }
        let module = DictationTranscriber(locale: supported, preset: .longDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () throws -> String in
            var text = ""
            for try await result in module.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}

// MARK: - sherpa-onnx engines

enum LabSherpa {
    /// Loads the model. Slow (seconds) — callers keep the result around.
    static func makeRecognizer(spec: SherpaSpec, dir: URL) throws -> SherpaOnnxOfflineRecognizer {
        func path(_ index: Int) -> String { dir.appendingPathComponent(spec.files[index]).path }
        // The recognizer aborts the app on a missing file, so check first.
        for name in spec.files where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            throw LabError("Model file missing: \(name). Download it again.")
        }

        // (The C config struct types aren't visible outside the SherpaOnnx module,
        // so each case builds its recognizer without naming them.)
        let recognizer: SherpaOnnxOfflineRecognizer
        switch spec.family {
        case .nemoTransducer:
            var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(), modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: path(3),
                transducer: sherpaOnnxOfflineTransducerModelConfig(encoder: path(0), decoder: path(1), joiner: path(2)),
                numThreads: 4, modelType: "nemo_transducer"))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        case .zipformer:
            var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(), modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: path(3),
                transducer: sherpaOnnxOfflineTransducerModelConfig(encoder: path(0), decoder: path(1), joiner: path(2)),
                numThreads: 4, modelType: "transducer"))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        case .moonshine:
            var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(), modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: path(4), numThreads: 4,
                moonshine: sherpaOnnxOfflineMoonshineModelConfig(preprocessor: path(0), encoder: path(1), uncachedDecoder: path(2), cachedDecoder: path(3))))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        case .senseVoice:
            var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(), modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: path(1), numThreads: 4,
                senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(model: path(0), language: "en", useInverseTextNormalization: true)))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        case .whisper:
            var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(), modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: path(2),
                whisper: sherpaOnnxOfflineWhisperModelConfig(encoder: path(0), decoder: path(1), language: "en"),
                numThreads: 4))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        case .canary:
            var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(), modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: path(2), numThreads: 4,
                canary: sherpaOnnxOfflineCanaryModelConfig(encoder: path(0), decoder: path(1))))
            recognizer = SherpaOnnxOfflineRecognizer(config: &config)
        }
        return recognizer
    }

    /// Decodes audio in chunks the model can take.
    static func decode(_ recognizer: SherpaOnnxOfflineRecognizer, spec: SherpaSpec, samples: [Float], sampleRate: Int) -> String {
        var pieces: [String] = []
        for chunk in split(samples, sampleRate: sampleRate, maxSeconds: spec.chunkSeconds) {
            let text = recognizer.decode(samples: chunk, sampleRate: sampleRate).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append(text) }
        }
        return pieces.joined(separator: " ")
    }

    /// Cuts long audio into pieces no longer than `maxSeconds`, each cut placed
    /// at the quietest moment in the last third of the window so words survive.
    static func split(_ samples: [Float], sampleRate: Int, maxSeconds: Double) -> [[Float]] {
        let maxLen = max(sampleRate, Int(maxSeconds * Double(sampleRate)))
        guard samples.count > maxLen else { return samples.isEmpty ? [] : [samples] }
        let window = max(1, sampleRate / 10)
        var chunks: [[Float]] = []
        var start = 0
        while samples.count - start > maxLen {
            let searchFrom = start + (maxLen * 2) / 3
            let searchTo = start + maxLen - window
            var bestAt = start + maxLen
            var bestEnergy = Float.greatestFiniteMagnitude
            var i = searchFrom
            while i <= searchTo {
                var energy: Float = 0
                for j in i..<(i + window) { energy += samples[j] * samples[j] }
                if energy < bestEnergy { bestEnergy = energy; bestAt = i + window / 2 }
                i += window
            }
            chunks.append(Array(samples[start..<bestAt]))
            start = bestAt
        }
        if start < samples.count { chunks.append(Array(samples[start...])) }
        return chunks
    }
}

// MARK: - Cloud engines

enum LabCloud {
    static func transcribe(vendor: CloudVendor, key: String, wav: Data) async throws -> String {
        switch vendor {
        case .deepgram:
            var request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true")!)
            request.httpMethod = "POST"
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            let json = try await send(request, body: wav)
            guard let results = json["results"] as? [String: Any],
                  let channels = results["channels"] as? [[String: Any]],
                  let alternatives = channels.first?["alternatives"] as? [[String: Any]],
                  let text = alternatives.first?["transcript"] as? String else { throw LabError("Unexpected Deepgram reply.") }
            return text

        case .openai:
            return try await multipartText(url: "https://api.openai.com/v1/audio/transcriptions",
                                           headers: ["Authorization": "Bearer \(key)"],
                                           fields: ["model": "gpt-transcribe"], fileField: "file", wav: wav)
        case .groq:
            return try await multipartText(url: "https://api.groq.com/openai/v1/audio/transcriptions",
                                           headers: ["Authorization": "Bearer \(key)"],
                                           fields: ["model": "whisper-large-v3-turbo", "language": "en"], fileField: "file", wav: wav)
        case .elevenlabs:
            return try await multipartText(url: "https://api.elevenlabs.io/v1/speech-to-text",
                                           headers: ["xi-api-key": key],
                                           fields: ["model_id": "scribe_v2"], fileField: "file", wav: wav)
        case .mistral:
            return try await multipartText(url: "https://api.mistral.ai/v1/audio/transcriptions",
                                           headers: ["Authorization": "Bearer \(key)"],
                                           fields: ["model": "voxtral-mini-latest"], fileField: "file", wav: wav)

        case .assemblyai:
            var upload = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
            upload.httpMethod = "POST"
            upload.setValue(key, forHTTPHeaderField: "authorization")
            let uploaded = try await send(upload, body: wav)
            guard let audioURL = uploaded["upload_url"] as? String else { throw LabError("AssemblyAI upload failed.") }
            var create = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
            create.httpMethod = "POST"
            create.setValue(key, forHTTPHeaderField: "authorization")
            create.setValue("application/json", forHTTPHeaderField: "content-type")
            let created = try await send(create, body: try JSONSerialization.data(withJSONObject: ["audio_url": audioURL]))
            guard let id = created["id"] as? String else { throw LabError("AssemblyAI didn't accept the job.") }
            for _ in 0..<120 {
                try await Task.sleep(for: .seconds(1))
                var poll = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript/\(id)")!)
                poll.setValue(key, forHTTPHeaderField: "authorization")
                let state = try await send(poll, body: nil)
                let status = state["status"] as? String ?? ""
                if status == "completed" { return state["text"] as? String ?? "" }
                if status == "error" { throw LabError(state["error"] as? String ?? "AssemblyAI failed.") }
            }
            throw LabError("AssemblyAI timed out.")

        case .soniox:
            let auth = ["Authorization": "Bearer \(key)"]
            let uploaded = try await multipartJSON(url: "https://api.soniox.com/v1/files", headers: auth, fields: [:], fileField: "file", wav: wav)
            guard let fileID = uploaded["id"] as? String else { throw LabError("Soniox upload failed.") }
            var create = URLRequest(url: URL(string: "https://api.soniox.com/v1/transcriptions")!)
            create.httpMethod = "POST"
            create.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            create.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let created = try await send(create, body: try JSONSerialization.data(withJSONObject: ["model": "stt-async-v6", "file_id": fileID]))
            guard let id = created["id"] as? String else { throw LabError("Soniox didn't accept the job.") }
            for _ in 0..<120 {
                try await Task.sleep(for: .seconds(1))
                var poll = URLRequest(url: URL(string: "https://api.soniox.com/v1/transcriptions/\(id)")!)
                poll.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let state = try await send(poll, body: nil)
                let status = state["status"] as? String ?? ""
                if status == "completed" {
                    var fetch = URLRequest(url: URL(string: "https://api.soniox.com/v1/transcriptions/\(id)/transcript")!)
                    fetch.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    return try await send(fetch, body: nil)["text"] as? String ?? ""
                }
                if status == "error" { throw LabError(state["error_message"] as? String ?? "Soniox failed.") }
            }
            throw LabError("Soniox timed out.")

        case .speechmatics:
            let config = #"{"type":"transcription","transcription_config":{"language":"en","operating_point":"enhanced"}}"#
            let created = try await multipartJSON(url: "https://eu1.asr.api.speechmatics.com/v2/jobs",
                                                  headers: ["Authorization": "Bearer \(key)"],
                                                  fields: ["config": config], fileField: "data_file", wav: wav)
            guard let id = created["id"] as? String else { throw LabError("Speechmatics didn't accept the job.") }
            for _ in 0..<120 {
                try await Task.sleep(for: .seconds(1))
                var poll = URLRequest(url: URL(string: "https://eu1.asr.api.speechmatics.com/v2/jobs/\(id)")!)
                poll.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let state = try await send(poll, body: nil)
                let status = (state["job"] as? [String: Any])?["status"] as? String ?? ""
                if status == "done" {
                    var fetch = URLRequest(url: URL(string: "https://eu1.asr.api.speechmatics.com/v2/jobs/\(id)/transcript?format=txt")!)
                    fetch.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    let (data, _) = try await URLSession.shared.data(for: fetch)
                    return String(data: data, encoding: .utf8) ?? ""
                }
                if status == "rejected" || status == "deleted" || status == "expired" { throw LabError("Speechmatics job \(status).") }
            }
            throw LabError("Speechmatics timed out.")
        }
    }

    /// Sends a request and returns its JSON object, turning HTTP errors into text.
    private static func send(_ request: URLRequest, body: Data?) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 120
        let reply: (Data, URLResponse)
        if let body {
            reply = try await URLSession.shared.upload(for: request, from: body)
        } else {
            reply = try await URLSession.shared.data(for: request)
        }
        let data = reply.0
        if let http = reply.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw LabError("HTTP \(http.statusCode): \(detail)")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func multipartJSON(url: String, headers: [String: String], fields: [String: String],
                                      fileField: String, wav: Data) async throws -> [String: Any] {
        let boundary = "myna-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"clip.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try await send(request, body: body)
    }

    private static func multipartText(url: String, headers: [String: String], fields: [String: String],
                                      fileField: String, wav: Data) async throws -> String {
        let json = try await multipartJSON(url: url, headers: headers, fields: fields, fileField: fileField, wav: wav)
        guard let text = json["text"] as? String else { throw LabError("Unexpected reply (no text).") }
        return text
    }
}
