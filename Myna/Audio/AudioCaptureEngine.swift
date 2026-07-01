import AVFoundation
import Foundation

/// Always-on, non-exclusive microphone capture.
///
/// Configures the audio session with `.mixWithOthers` so Myna listens *alongside*
/// other audio apps instead of seizing the mic — music, podcasts and other
/// recorders keep working. Incoming audio is resampled to the 16 kHz mono float
/// format Whisper expects, and an energy-based voice-activity detector slices the
/// stream into "utterances": a burst of speech followed by a short pause. Each
/// completed utterance is handed to `onUtterance` for transcription.
///
/// Nothing is ever written to disk — audio lives only in memory long enough to be
/// transcribed, then it's gone.
@MainActor
final class AudioCaptureEngine: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    /// Smoothed input level in 0...1, for the orb.
    @Published private(set) var audioLevel: Double = 0
    /// True while the VAD believes someone is currently speaking.
    @Published private(set) var isSpeaking = false
    @Published private(set) var lastError: String?

    /// Called on the main actor with 16 kHz mono samples when an utterance completes.
    var onUtterance: (([Float], Date) -> Void)?

    // Tuning.
    private let sampleRate: Double = 16_000
    private let silenceThreshold: Float = 0.012          // RMS below this counts as silence
    private let hangoverSeconds: Double = 0.7            // trailing silence that ends an utterance
    private let minUtteranceSeconds: Double = 0.35       // drop blips shorter than this
    private let maxUtteranceSeconds: Double = 28.0       // flush before Whisper's 30 s window
    private let preRollSeconds: Double = 0.3             // keep a little audio before speech starts

    private let audioEngine = AVAudioEngine()
    // Written on the main actor in start()/stop() (before the tap is installed and
    // after it's removed); read on the audio thread in process(). No overlap → safe.
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var targetFormat: AVAudioFormat?

    // Utterance assembly (audio-thread state, guarded by @MainActor hops for publishing).
    private var utterance: [Float] = []
    private var preRoll: [Float] = []
    private var voicedSamples = 0
    private var trailingSilenceSamples = 0
    private var capturing = false

    // MARK: - Permission

    static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static var micAuthorized: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        lastError = nil
        do {
            let session = AVAudioSession.sharedInstance()
            // Non-exclusive: co-exist with other audio rather than interrupting it.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard
                let target = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                ),
                let converter = AVAudioConverter(from: inputFormat, to: target)
            else {
                throw CaptureError.formatUnavailable
            }
            self.targetFormat = target
            self.converter = converter

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.process(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
        } catch {
            lastError = "Couldn't start listening: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        // Discard any half-captured utterance; the user chose to stop.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        isSpeaking = false
        audioLevel = 0
        capturing = false
        utterance.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        voicedSamples = 0
        trailingSilenceSamples = 0
    }

    // MARK: - Audio processing (called on the audio thread)

    private nonisolated func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let target = targetFormat else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }

        let frames = Int(out.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
        let rms = Self.rms(samples)

        Task { @MainActor [weak self] in
            self?.ingest(samples: samples, rms: rms)
        }
    }

    private func ingest(samples: [Float], rms: Float) {
        // Level for the orb: fast attack, slow decay.
        let level = min(1.0, Double(rms) * 8.0)
        audioLevel = max(level, audioLevel * 0.85)

        let isVoiced = rms > silenceThreshold
        let hangoverLimit = Int(hangoverSeconds * sampleRate)
        let maxLimit = Int(maxUtteranceSeconds * sampleRate)
        let preRollLimit = Int(preRollSeconds * sampleRate)

        if isVoiced {
            if !capturing {
                capturing = true
                isSpeaking = true
                utterance = preRoll     // seed with a little lead-in so first word isn't clipped
            }
            utterance.append(contentsOf: samples)
            voicedSamples += samples.count
            trailingSilenceSamples = 0
        } else if capturing {
            // Still within an utterance, riding out a pause.
            utterance.append(contentsOf: samples)
            trailingSilenceSamples += samples.count
            if trailingSilenceSamples >= hangoverLimit {
                flushUtterance()
            }
        } else {
            // Idle: keep a rolling pre-roll of the most recent audio.
            preRoll.append(contentsOf: samples)
            if preRoll.count > preRollLimit {
                preRoll.removeFirst(preRoll.count - preRollLimit)
            }
        }

        if capturing && utterance.count >= maxLimit {
            flushUtterance()
        }
    }

    /// Emits the current utterance if it contains enough real speech, then resets.
    private func flushUtterance() {
        defer {
            capturing = false
            isSpeaking = false
            utterance.removeAll(keepingCapacity: true)
            // Drop pre-roll so the next utterance doesn't inherit stale audio
            // (e.g. after a max-length forced split of continuous speech).
            preRoll.removeAll(keepingCapacity: true)
            voicedSamples = 0
            trailingSilenceSamples = 0
        }
        guard capturing else { return }
        let voicedSeconds = Double(voicedSamples) / sampleRate
        guard voicedSeconds >= minUtteranceSeconds else { return }
        let payload = utterance
        onUtterance?(payload, .now)
    }

    private nonisolated static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    enum CaptureError: LocalizedError {
        case formatUnavailable
        var errorDescription: String? {
            switch self {
            case .formatUnavailable: return "This device's microphone format is unsupported."
            }
        }
    }
}
