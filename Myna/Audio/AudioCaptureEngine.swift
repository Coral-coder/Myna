import AVFoundation
import Foundation
import UIKit

/// Always-on, non-exclusive, self-healing microphone capture.
///
/// Configures the audio session with `.mixWithOthers` so Myna listens *alongside*
/// other audio apps instead of seizing the mic — music, podcasts and other
/// recorders keep working. Incoming audio is resampled to the 16 kHz mono float
/// format Whisper expects, and an energy-based voice-activity detector slices the
/// stream into "utterances": a burst of speech followed by a short pause. Each
/// completed utterance is handed to `onUtterance` for transcription.
///
/// **Resilience.** Once started, the engine *wants to run* until explicitly
/// stopped. When iOS sidelines it — a phone call, Siri, another app taking
/// exclusive audio, a route change, or a media-services reset — it observes the
/// relevant notifications and, backed by a short retry loop, re-acquires the
/// microphone the instant it becomes available again. It never fights another
/// app for exclusive audio (staying a good citizen), but it never gives up its
/// place either.
///
/// Nothing is ever written to disk — audio lives only in memory long enough to be
/// transcribed, then it's gone.
@MainActor
final class AudioCaptureEngine: NSObject, ObservableObject {
    /// True while the engine is actively tapping the microphone.
    @Published private(set) var isRunning = false
    /// True while we *want* to be running but the mic is currently unavailable
    /// (interrupted or locked out) and we're retrying to re-acquire it.
    @Published private(set) var isReacquiring = false
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
    private let reacquireInterval: TimeInterval = 2.0    // how often to retry grabbing the mic

    // The engine is a var so it can be rebuilt after a media-services reset.
    private var audioEngine = AVAudioEngine()
    // Written on the main actor while the tap is detached; read on the audio
    // thread in process(). No overlap → safe.
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var targetFormat: AVAudioFormat?

    /// User intent: stays true from start() until stop(), across interruptions.
    /// Exposed via `isActive` so callers can distinguish "meant to be listening"
    /// from the momentary `isRunning`.
    private var wantsToRun = false

    /// Whether Myna intends to be listening (true even while re-acquiring the mic).
    var isActive: Bool { wantsToRun }
    private var reacquireTimer: Timer?
    private var observersRegistered = false

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
        wantsToRun = true
        lastError = nil
        registerObservers()
        attemptStart()
        // If the mic wasn't available right away, keep trying until it is.
        if !isRunning { beginReacquireLoop() }
    }

    func stop() {
        wantsToRun = false
        stopReacquireLoop()
        teardownEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
        isReacquiring = false
        isSpeaking = false
        audioLevel = 0
        capturing = false
        utterance.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        voicedSamples = 0
        trailingSilenceSamples = 0
    }

    /// One attempt to activate the session and start the engine. Non-fatal on
    /// failure — the retry loop / notifications will try again.
    private func attemptStart() {
        guard wantsToRun, !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // Non-exclusive: co-exist with other audio rather than interrupting it.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
            )
            // Ask the system to spare us from alert-driven interruptions where it can.
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            // A zero sample-rate input means no usable route yet (e.g. mid-call). Retry later.
            guard inputFormat.sampleRate > 0 else { throw CaptureError.noInputRoute }
            guard
                let target = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                ),
                let converter = AVAudioConverter(from: inputFormat, to: target)
            else {
                throw CaptureError.noInputRoute
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
            isReacquiring = false
            stopReacquireLoop()
        } catch {
            // Transient (interruption / lockout / route not ready). Tear down the
            // half-built graph and let the retry loop pick it up.
            teardownEngine()
            isRunning = false
        }
    }

    private func teardownEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
    }

    // MARK: - Re-acquisition

    private func beginReacquireLoop() {
        guard wantsToRun, !isRunning, reacquireTimer == nil else { return }
        isReacquiring = true
        let timer = Timer(timeInterval: reacquireInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reacquireTick() }
        }
        // Run on the common run-loop modes so retries keep firing while scrolling, etc.
        RunLoop.main.add(timer, forMode: .common)
        reacquireTimer = timer
    }

    private func stopReacquireLoop() {
        reacquireTimer?.invalidate()
        reacquireTimer = nil
        if !isRunning { isReacquiring = false }
    }

    private func reacquireTick() {
        guard wantsToRun else { stopReacquireLoop(); return }
        guard !isRunning else { stopReacquireLoop(); return }
        attemptStart()
    }

    // MARK: - System notifications (interruptions, routes, resets)

    private func registerObservers() {
        guard !observersRegistered else { return }
        observersRegistered = true
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        center.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: session)
        center.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: session)
        center.addObserver(
            self, selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification, object: session)
        center.addObserver(
            self, selector: #selector(handleEngineConfigChange(_:)),
            name: .AVAudioEngineConfigurationChange, object: audioEngine)
        // Belt and suspenders: re-check whenever we return to the foreground.
        center.addObserver(
            self, selector: #selector(handleReactivateChance(_:)),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// Notifications can arrive on arbitrary threads; hop to the main actor.
    /// Extract the (Sendable) interruption type here so nothing non-Sendable crosses.
    @objc private nonisolated func handleInterruption(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        Task { @MainActor [weak self] in self?.onInterruption(typeRaw: raw) }
    }
    @objc private nonisolated func handleRouteChange(_ note: Notification) {
        Task { @MainActor [weak self] in self?.onRouteChange() }
    }
    @objc private nonisolated func handleMediaServicesReset(_ note: Notification) {
        Task { @MainActor [weak self] in self?.onMediaServicesReset() }
    }
    @objc private nonisolated func handleEngineConfigChange(_ note: Notification) {
        Task { @MainActor [weak self] in self?.onEngineConfigChange() }
    }
    @objc private nonisolated func handleReactivateChance(_ note: Notification) {
        Task { @MainActor [weak self] in self?.recoverIfNeeded() }
    }

    private func onInterruption(typeRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // The system has taken the mic (call/Siri/exclusive app). Our engine
            // is stopped; keep wanting to run and start trying to get it back.
            isRunning = false
            if wantsToRun { beginReacquireLoop() }
        case .ended:
            // Regardless of the .shouldResume hint, we want the mic back now.
            recoverIfNeeded()
        @unknown default:
            recoverIfNeeded()
        }
    }

    private func onRouteChange() {
        // A new/removed device can invalidate the running graph — rebuild it.
        guard wantsToRun else { return }
        if isRunning { teardownEngine(); isRunning = false }
        recoverIfNeeded()
    }

    private func onEngineConfigChange() {
        // The engine stops itself on a configuration change; bring it back up.
        guard wantsToRun else { return }
        isRunning = false
        recoverIfNeeded()
    }

    private func onMediaServicesReset() {
        // The entire audio stack was reset — rebuild the engine from scratch.
        guard wantsToRun else { return }
        teardownEngine()
        NotificationCenter.default.removeObserver(
            self, name: .AVAudioEngineConfigurationChange, object: audioEngine)
        converter = nil
        targetFormat = nil
        audioEngine = AVAudioEngine()
        // Re-observe config changes on the new engine instance.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleEngineConfigChange(_:)),
            name: .AVAudioEngineConfigurationChange, object: audioEngine)
        isRunning = false
        recoverIfNeeded()
    }

    /// Try immediately, and if that fails, fall back to the retry loop.
    private func recoverIfNeeded() {
        guard wantsToRun, !isRunning else { return }
        attemptStart()
        if !isRunning { beginReacquireLoop() }
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
        /// No usable microphone route right now (e.g. mid-call or being reset).
        /// Treated as transient — the retry loop will try again.
        case noInputRoute
        var errorDescription: String? {
            switch self {
            case .noInputRoute: return "The microphone isn't available right now."
            }
        }
    }
}
