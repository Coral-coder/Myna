import AVFoundation
import Foundation
import Speech
import UIKit

/// Continuous, fully on-device speech capture.
///
/// Runs an `AVAudioEngine` tap into `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition = true`, so no audio or transcript ever
/// touches the network. The recognition task is rotated periodically to keep
/// long all-day sessions stable; each finalized utterance is handed to
/// `onFinalText`. Phone calls, Siri and other interruptions pause listening,
/// which picks back up by itself when they end.
@MainActor
final class SpeechListener: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var liveTranscript = ""
    /// Smoothed microphone level in 0...1 for the orb animation.
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var lastError: String?

    /// Called with each finalized chunk of speech and the time it was heard.
    var onFinalText: ((String, Date) -> Void)?
    /// Called with the full in-progress text of the current recognition task.
    var onPartialText: ((String) -> Void)?
    /// Called once when a recognition task finishes, with its final text.
    var onTaskFinished: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.preferredLanguages.first ?? "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rotationTimer: Timer?
    /// Bumped for every recognition task so late callbacks from old tasks are ignored.
    private var generation = 0
    /// Recognition paused (e.g. while Myna is speaking) but the session stays up.
    private var isPaused = false
    private var resumeAfterInterruption = false
    /// We want to be listening, but something (backgrounding, an interruption)
    /// stopped the engine; resume the moment the app is active and the mic is
    /// available again. The iPhone can't open the mic while backgrounded, so
    /// restarting the engine there would crash — we wait instead.
    private var wantsToListen = false

    /// Rotate the recognition task once a minute so a single task never grows unbounded.
    private let taskRotationInterval: TimeInterval = 60

    /// When true, an external source (the Bee bracelet) is driving audio, so the
    /// phone's own microphone is kept out of the recognition request. Read from
    /// the audio-thread tap, so it's a plain flag.
    nonisolated(unsafe) private var externalSourceActive = false

    /// Far-field boost, read from the audio-thread tap. 1 = off. Updated from the
    /// main actor when the Microphone sensitivity slider changes.
    nonisolated(unsafe) private var sensitivity: Float = SpeechListener.storedSensitivity

    nonisolated static let sensitivityKey = "myna.micSensitivity"
    // nonisolated so it can seed the audio-thread `sensitivity` default; it only
    // reads UserDefaults, which is thread-safe.
    nonisolated static var storedSensitivity: Float {
        let v = UserDefaults.standard.object(forKey: sensitivityKey) as? Double
        return Float(v ?? 3.0)
    }

    /// How hard Myna boosts distant speech (1...8). Takes effect on the next buffer.
    func setSensitivity(_ value: Float) {
        sensitivity = min(max(value, 1), 8)
    }

    // MARK: - Segment audio capture (for Whisper)

    /// While true, each mic buffer is also written to `segmentFile` so Whisper
    /// can re-transcribe the whole conversation from audio. Read on the audio thread.
    nonisolated(unsafe) private var captureActive = false
    nonisolated(unsafe) private var segmentFile: AVAudioFile?
    /// The live mic format, captured in `start()` so a segment file can be opened.
    nonisolated(unsafe) private var captureFormat: AVAudioFormat?
    private var segmentURL: URL?

    /// Start recording the current conversation's audio to a temp file.
    func beginSegmentCapture() {
        guard captureFormat != nil, segmentFile == nil else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-segment-\(UUID().uuidString).caf")
        guard let format = captureFormat, let file = try? AVAudioFile(forWriting: url, settings: format.settings) else { return }
        segmentURL = url
        segmentFile = file
        captureActive = true
    }

    /// Stop recording and hand back the file URL (caller transcribes, then deletes it).
    func takeSegmentAudioURL() -> URL? {
        captureActive = false
        let url = segmentURL
        segmentFile = nil   // closing the file flushes it to disk
        segmentURL = nil
        return url
    }

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleMediaReset(_:)), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        center.addObserver(self, selector: #selector(handleBecameActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// The mic can only be opened while the app is foreground-active.
    private var appIsActive: Bool { UIApplication.shared.applicationState == .active }

    // MARK: - Permissions

    static func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    static var hasPermissions: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: - Lifecycle

    func start() {
        guard !isListening else { return }
        // Remember the intent even if we can't start right now, so we resume
        // when the app is next active (see handleBecameActive).
        wantsToListen = true
        // The iPhone microphone can't be opened from the background; trying would
        // throw or, worse, install a tap on a zero-rate format and crash. Defer.
        guard appIsActive else { return }
        lastError = nil
        do {
            let session = AVAudioSession.sharedInstance()
            // playAndRecord so Myna can answer out loud without dropping the mic.
            // .default (not .measurement) keeps Apple's automatic gain and noise
            // handling on, which picks up farther, quieter voices in a room;
            // .measurement disables that processing and left distant speech faint.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            // When the mic is unavailable (just backgrounded, taken by a call, or
            // revoked) the input format comes back with a 0 sample rate, and
            // installTap would hit a fatal assertion. Bail gracefully instead —
            // this is the background-crash fix.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                lastError = "The microphone isn't available right now."
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            captureFormat = format
            inputNode.removeTap(onBus: 0)
            // Pass format: nil so CoreAudio uses the input node's own format. An
            // explicit format that doesn't exactly match the node makes installTap
            // raise an Objective-C exception (which Swift can't catch) and the app
            // aborts — seen on iOS 26/27. nil is the mismatch-proof choice.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                // While the bracelet is the source, the mic stays off the request.
                if self?.externalSourceActive != true {
                    // Lift distant, quiet speech so the recognizer can hear it.
                    Self.boost(buffer, gain: self?.sensitivity ?? 1)
                    self?.request?.append(buffer)
                    // Also capture the audio for Whisper, if a segment is recording.
                    if self?.captureActive == true { try? self?.segmentFile?.write(from: buffer) }
                }
                let level = Self.rms(of: buffer)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Attack fast, decay slow — feels alive without flickering.
                    self.audioLevel = max(level, self.audioLevel * 0.86)
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            isPaused = false
            startRecognitionTask()

            rotationTimer?.invalidate()
            rotationTimer = Timer.scheduledTimer(withTimeInterval: taskRotationInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rotateRecognitionTask() }
            }
        } catch {
            lastError = "Could not start listening: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        resumeAfterInterruption = false
        wantsToListen = false
        rotationTimer?.invalidate()
        rotationTimer = nil
        flushPartialIfMeaningful()
        endTask()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
        isPaused = false
        liveTranscript = ""
        audioLevel = 0
        captureActive = false
        segmentFile = nil
        segmentURL = nil
    }

    /// Stops transcribing without releasing the microphone — used while Myna talks.
    func pauseRecognition() {
        guard isListening, !isPaused else { return }
        flushPartialIfMeaningful()
        endTask()
        isPaused = true
    }

    func resumeRecognition() {
        guard isPaused else { return }
        isPaused = false
        if isListening { startRecognitionTask() }
    }

    // MARK: - External audio source (Bee bracelet)

    /// Switch recognition to an external source: the phone's microphone stops
    /// feeding the recognizer, and `feedExternalAudio` drives it instead. The
    /// audio session and recognition task stay up, so conversation
    /// segmentation, wake-word commands and notes all keep working unchanged.
    func beginExternalSource() {
        externalSourceActive = true
    }

    /// Hand the recognizer a buffer of PCM decoded from the bracelet.
    func feedExternalAudio(_ buffer: AVAudioPCMBuffer) {
        guard externalSourceActive, !isPaused else { return }
        request?.append(buffer)
        let level = Self.rms(of: buffer)
        audioLevel = max(level, audioLevel * 0.86)
    }

    /// Hand audio back to the phone's microphone.
    func endExternalSource() {
        externalSourceActive = false
        audioLevel = 0
    }

    // MARK: - Recognition

    private func startRecognitionTask() {
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition is not available on this device."
            return
        }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        newRequest.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            // The privacy contract: recognition never leaves the device.
            newRequest.requiresOnDeviceRecognition = true
        }
        request = newRequest
        generation += 1
        let taskGeneration = generation

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, taskGeneration == self.generation else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.liveTranscript = text
                    if result.isFinal {
                        self.deliver(text)
                        self.liveTranscript = ""
                        self.onTaskFinished?(text)
                        if self.isListening && !self.isPaused {
                            self.startRecognitionTask()
                        }
                    } else {
                        self.onPartialText?(text)
                    }
                } else if error != nil, self.isListening, !self.isPaused {
                    // On-device tasks occasionally end after silence; just spin up a fresh one.
                    let pending = self.liveTranscript
                    self.flushPartialIfMeaningful()
                    self.onTaskFinished?(pending)
                    self.startRecognitionTask()
                }
            }
        }
    }

    /// Ends the current task gracefully; its final result is delivered via the handler above.
    private func rotateRecognitionTask() {
        guard isListening, !isPaused else { return }
        request?.endAudio()
    }

    /// Tears down the current task without waiting for its result.
    private func endTask() {
        let pending = liveTranscript
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        onTaskFinished?(pending)
    }

    private func flushPartialIfMeaningful() {
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            deliver(text)
            liveTranscript = ""
        }
    }

    private func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onFinalText?(trimmed, .now)
    }

    // MARK: - Interruptions

    @objc private nonisolated func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .began:
                // A call or Siri took the mic; remember to come back.
                if self.isListening {
                    self.resumeAfterInterruption = true
                    self.stopForInterruption()
                }
            case .ended:
                if self.resumeAfterInterruption {
                    self.resumeAfterInterruption = false
                    // Only reopen the mic if we're foreground-active; otherwise
                    // wantsToListen stays set and handleBecameActive resumes us.
                    guard self.appIsActive else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    self.start()
                }
            @unknown default:
                break
            }
        }
    }

    @objc private nonisolated func handleMediaReset(_ notification: Notification) {
        Task { @MainActor in
            guard self.isListening else { return }
            self.stopForInterruption()
            guard self.appIsActive else { return }
            try? await Task.sleep(for: .seconds(1))
            self.start()
        }
    }

    /// Back in the foreground: reopen the mic if we meant to be listening but an
    /// interruption or backgrounding had stopped the engine.
    @objc private nonisolated func handleBecameActive(_ notification: Notification) {
        Task { @MainActor in
            guard self.wantsToListen, !self.isListening, !self.isPaused else { return }
            try? await Task.sleep(for: .milliseconds(300))
            self.start()
        }
    }

    private func stopForInterruption() {
        let resume = resumeAfterInterruption
        stop()
        resumeAfterInterruption = resume
        // An interruption or backgrounding is temporary — keep the intent to
        // listen so we resume automatically.
        wantsToListen = true
    }

    /// Applies the far-field boost in place on the live mic buffer, using the
    /// same gate → gain → soft-clip as `AudioGain` (which is unit-tested). Runs
    /// on the audio thread, so it stays allocation-free.
    private nonisolated static func boost(_ buffer: AVAudioPCMBuffer, gain: Float) {
        guard gain > 1.001, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)

        // Gate: don't amplify a near-silent room into phantom speech.
        var sum: Float = 0
        let first = channels[0]
        for i in 0..<frames { sum += first[i] * first[i] }
        guard (sum / Float(frames)).squareRoot() >= 0.004 else { return }

        for c in 0..<channelCount {
            let samples = channels[c]
            for i in 0..<frames { samples[i] = tanhf(samples[i] * gain) }
        }
    }

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames {
            sum += data[i] * data[i]
        }
        let rms = sqrt(sum / Float(frames))
        // Map raw RMS (~0...0.3 for speech) onto a friendly 0...1 curve.
        return min(1.0, Double(rms) * 6.0)
    }
}
