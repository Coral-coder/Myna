import AVFoundation
import Foundation

/// Myna's speaking voice. Prefers the best-quality English voice installed
/// (Settings → Accessibility → Spoken Content → Voices lets you download
/// premium ones) and pauses recognition while talking so Myna never
/// transcribes itself.
@MainActor
final class VoiceReply: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false

    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "myna.speakReplies") as? Bool ?? true
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        // Speak through the session the listener already holds, so talking
        // back never tears down the microphone.
        synthesizer.usesApplicationAudioSession = true
    }

    func say(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        utterance.pitchMultiplier = 1.03
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private static let bestVoice: AVSpeechSynthesisVoice? = {
        let language = Locale.preferredLanguages.first ?? "en-US"
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        return candidates.first { $0.quality == .premium && $0.language == language }
            ?? candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced && $0.language == language }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }()

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.isSpeaking {
                self.isSpeaking = true
                self.onStart?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishIfIdle() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishIfIdle() }
    }

    private func finishIfIdle() {
        guard !synthesizer.isSpeaking, isSpeaking else { return }
        isSpeaking = false
        onFinish?()
    }
}
