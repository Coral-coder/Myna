import CoreML
import Foundation
import WhisperKit

/// On-device speech-to-text with OpenAI Whisper (via WhisperKit) — noticeably
/// more accurate than Apple's recognizer on distant, noisy or overlapping
/// speech. Myna keeps Apple's fast recognizer for the live "Myna …" wake word
/// (low latency); Whisper re-transcribes each finished conversation's audio to
/// produce the note. The model is downloaded once on first use (like the MLX
/// models) and runs entirely on the device.
@MainActor
final class WhisperTranscriber: ObservableObject {
    enum State: Equatable {
        case notLoaded
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notLoaded

    static let enabledKey = "myna.useWhisper"

    /// Small, fast English model — a good accuracy/size tradeoff for a phone.
    private let modelName = "base.en"
    private var pipe: WhisperKit?
    private var loadTask: Task<Void, Never>?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { load() }
    }

    /// Download (first time) and warm up the model.
    func load() {
        guard pipe == nil, loadTask == nil else { return }
        state = .loading
        let model = modelName
        loadTask = Task { [weak self] in
            do {
                // CPU + Neural Engine only: iOS forbids GPU work from the
                // background, and WhisperKit's default GPU mel stage would fail
                // (or take Myna down) while the phone is locked.
                let compute = ModelComputeOptions(
                    melCompute: .cpuOnly,
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                )
                let kit = try await WhisperKit(WhisperKitConfig(model: model, computeOptions: compute))
                await MainActor.run {
                    self?.pipe = kit
                    self?.state = .ready
                }
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
            await MainActor.run { self?.loadTask = nil }
        }
    }

    /// Transcribe an audio file of any format (WhisperKit resamples to 16 kHz
    /// mono itself). Returns nil if Whisper isn't ready or produced nothing, so
    /// the caller can fall back to Apple's transcript.
    func transcribe(path: String) async -> String? {
        // One at a time: two 20-minute files decoding at once doubled memory.
        let previous = queueTail
        let job = Task { @MainActor [weak self] () -> String? in
            await previous?.value
            return await self?.runTranscription(path: path)
        }
        queueTail = Task { _ = await job.value }
        return await job.value
    }

    private var queueTail: Task<Void, Never>?

    private func runTranscription(path: String) async -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if pipe == nil {
            load()
            await loadTask?.value
        }
        guard let pipe else { return nil }
        do {
            let results = try await pipe.transcribe(audioPath: path)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            CrashReporter.log("whisper failed: \(error.localizedDescription)")
            return nil
        }
    }
}
