import AVFoundation
import Foundation
import Speech
import UIKit
import UserNotifications

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
    /// True while the bracelet (not the phone mic) is driving recognition.
    @Published private(set) var usingExternalSource = false
    /// Count of recognized partials/finals seen — a heartbeat the debug view shows.
    @Published private(set) var recognitionTicks = 0
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
    /// Called (at most every couple of seconds) while the mic hears voice-level
    /// sound. Lets the pilot keep recording for Whisper even when Apple's
    /// recognizer isn't producing text (it can stall in the background).
    var onVoiceActivity: (() -> Void)?
    private var lastVoiceActivity: Date = .distantPast
    /// Recognition tasks that failed right after starting, for backoff. A
    /// recognizer that errors instantly in a tight loop pins the CPU and gets
    /// Myna killed by iOS.
    private var quickFailures = 0
    private var taskStartedAt: Date = .distantPast
    private var restartPending = false
    private var lastStartAt: Date = .distantPast

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
    private(set) var wantsToListen = false

    /// Guards everything the audio-thread tap touches (`tapRequest`,
    /// `segmentFile`, `captureActive`). Swapping these on the main thread while
    /// the tap is mid-write was a use-after-free crash.
    private let tapLock = NSLock()
    nonisolated(unsafe) private var tapRequest: SFSpeechAudioBufferRecognitionRequest?

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
        guard let format = captureFormat, segmentURL == nil else { return }
        let url = Self.segmentDirectory.appendingPathComponent("segment-\(UUID().uuidString).caf")
        // AAC in a CAF keeps a 20-minute conversation to a few MB (raw float
        // PCM was ~230 MB) and CAF stays readable even if Myna dies mid-write.
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(format.channelCount, 2),
            AVEncoderBitRateKey: 48_000,
        ]
        let file = (try? AVAudioFile(forWriting: url, settings: aac, commonFormat: format.commonFormat, interleaved: format.isInterleaved))
            ?? (try? AVAudioFile(forWriting: url, settings: format.settings))
        guard let file else { return }
        segmentURL = url
        tapLock.lock()
        segmentFile = file
        captureActive = true
        tapLock.unlock()
    }

    /// Stop recording and hand back the file URL (caller transcribes, then deletes it).
    func takeSegmentAudioURL() -> URL? {
        tapLock.lock()
        captureActive = false
        segmentFile = nil   // closing the file flushes it to disk
        tapLock.unlock()
        let url = segmentURL
        segmentURL = nil
        return url
    }

    /// The file the current conversation is being recorded to, if any.
    var currentSegmentPath: String? { segmentURL?.path }

    /// Segment audio lives in Application Support (not tmp) so a conversation
    /// recorded before a crash can still be transcribed on the next launch.
    static let segmentDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Segments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleMediaReset(_:)), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        center.addObserver(self, selector: #selector(handleBecameActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
        // A route change (AirPods, car, a call) stops AVAudioEngine silently;
        // without this Myna looked "on" but heard nothing for the rest of the day.
        center.addObserver(self, selector: #selector(handleEngineConfigChange(_:)), name: .AVAudioEngineConfigurationChange, object: audioEngine)
    }

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

    /// One-line recognizer status for the debug view.
    var recognizerStatus: String {
        if !Self.hasPermissions { return "Speech permission not granted" }
        guard let recognizer else { return "No recognizer for this locale" }
        if !recognizer.isAvailable { return "Recognizer unavailable right now" }
        if let lastError { return lastError }
        if isPaused { return "Paused (Myna is speaking)" }
        if isListening { return usingExternalSource ? "Transcribing bracelet audio" : "Transcribing mic" }
        return "Idle"
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
        // Started (or resumed after a call) while backgrounded: with the "audio"
        // background mode iOS usually allows it. If it doesn't, the guards
        // below fail softly and we resume when Myna is next opened.
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
                CrashReporter.log("mic unavailable (rate \(format.sampleRate)) state=\(UIApplication.shared.applicationState.rawValue)")
                notifyStoppedIfBackground()
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
                guard let self else { return }
                let fromMic = !self.externalSourceActive
                if fromMic {
                    // Lift distant, quiet speech so the recognizer can hear it.
                    Self.boost(buffer, gain: self.sensitivity)
                    self.tapLock.lock()
                    self.tapRequest?.append(buffer)
                    // Also capture the audio for Whisper, if a segment is recording.
                    if self.captureActive { try? self.segmentFile?.write(from: buffer) }
                    self.tapLock.unlock()
                }
                let level = Self.rms(of: buffer)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Attack fast, decay slow — feels alive without flickering.
                    self.audioLevel = max(level, self.audioLevel * 0.86)
                    if fromMic, level > 0.3, Date.now.timeIntervalSince(self.lastVoiceActivity) > 2 {
                        self.lastVoiceActivity = .now
                        self.onVoiceActivity?()
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            isPaused = false
            quickFailures = 0
            lastStartAt = .now
            startRecognitionTask()
            CrashReporter.log("listening started state=\(UIApplication.shared.applicationState.rawValue)")

            rotationTimer?.invalidate()
            rotationTimer = Timer.scheduledTimer(withTimeInterval: taskRotationInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rotateRecognitionTask() }
            }
        } catch {
            lastError = "Could not start listening: \(error.localizedDescription)"
            CrashReporter.log("start failed: \(error.localizedDescription) state=\(UIApplication.shared.applicationState.rawValue)")
            // Keep the intent so we come back on the next foreground.
            stopForInterruption()
            notifyStoppedIfBackground()
        }
    }

    /// iOS refused the mic while Myna was in the background — tell the user,
    /// once, instead of silently recording nothing.
    private func notifyStoppedIfBackground() {
        guard !appIsActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "Myna stopped listening"
        content.body = "iOS paused the microphone. Open Myna to resume recording."
        let request = UNNotificationRequest(identifier: "myna.micStopped", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
        // Leave a segment that's recording alone: the pilot takes its URL (or the
        // next launch recovers it) — dropping it here lost the audio.
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
        usingExternalSource = true
    }

    /// Hand the recognizer a buffer of PCM decoded from the bracelet.
    func feedExternalAudio(_ buffer: AVAudioPCMBuffer) {
        guard externalSourceActive, !isPaused else { return }
        tapLock.lock()
        tapRequest?.append(buffer)
        tapLock.unlock()
        let level = Self.rms(of: buffer)
        audioLevel = max(level, audioLevel * 0.86)
    }

    /// Hand audio back to the phone's microphone.
    func endExternalSource() {
        externalSourceActive = false
        usingExternalSource = false
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
        setRequest(newRequest)
        generation += 1
        let taskGeneration = generation
        taskStartedAt = .now

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, taskGeneration == self.generation else { return }
                if let result {
                    self.quickFailures = 0
                    self.recognitionTicks += 1
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
                    self.restartRecognitionWithBackoff()
                }
            }
        }
    }

    /// Restart a task that errored. One that died within seconds of starting
    /// waits progressively longer (up to 30s) so a failing recognizer can't
    /// spin the CPU; the mic and Whisper capture keep running meanwhile.
    private func restartRecognitionWithBackoff() {
        guard !restartPending else { return }
        if Date.now.timeIntervalSince(taskStartedAt) < 3 {
            quickFailures += 1
        } else {
            quickFailures = 0
        }
        guard quickFailures > 1 else {
            startRecognitionTask()
            return
        }
        let delay = min(30.0, pow(2.0, Double(quickFailures - 1)))
        restartPending = true
        // No live task meanwhile: buffers go nowhere instead of to a dead request.
        setRequest(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.restartPending = false
            if self.isListening, !self.isPaused, self.task == nil || self.request == nil {
                self.startRecognitionTask()
            }
        }
    }

    private func setRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        request = newRequest
        tapLock.lock()
        tapRequest = newRequest
        tapLock.unlock()
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
        setRequest(nil)
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
                    // Background-audio apps may resume after a call; if iOS says
                    // no, start() fails softly and we resume on next foreground.
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
            try? await Task.sleep(for: .seconds(1))
            self.start()
        }
    }

    @objc private nonisolated func handleEngineConfigChange(_ notification: Notification) {
        Task { @MainActor in
            // Engines often post one of these right after starting; ignore that
            // and never restart more than once every few seconds.
            guard self.isListening, Date.now.timeIntervalSince(self.lastStartAt) > 3 else { return }
            CrashReporter.log("audio route/config changed — restarting mic")
            self.stopForInterruption()
            try? await Task.sleep(for: .milliseconds(500))
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
