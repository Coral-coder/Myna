import AVFoundation
import Foundation

/// Myna's speaking voice. Prefers the best-quality English voice installed
/// (Settings → Accessibility → Spoken Content → Voices lets you download
/// premium ones) and pauses recognition while talking so Myna never
/// transcribes itself.
@MainActor
final class VoiceReply: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false

    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?

    /// On-device neural voice (sherpa-onnx). When active, Myna speaks with it
    /// instead of the system synthesizer. Set by AppServices.
    weak var neural: NeuralVoice?
    private var player: AVAudioPlayer?

    private let synthesizer = AVSpeechSynthesizer()

    static let voiceKey = "myna.voiceIdentifier"

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "myna.speakReplies") as? Bool ?? true
    }

    /// The voice the user picked, if any (empty = let Myna choose the best).
    private var chosenVoiceID: String {
        UserDefaults.standard.string(forKey: Self.voiceKey) ?? ""
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
        if neural?.isActive == true {
            speakNeural(text)
        } else {
            speak(text, voice: resolvedVoice())
        }
    }

    /// Speak with the on-device neural voice; synthesize to a WAV and play it.
    /// Any failure drops cleanly to the system voice.
    private func speakNeural(_ text: String) {
        guard let neural else { speak(text, voice: resolvedVoice()); return }
        if !isSpeaking { isSpeaking = true; onStart?() }
        Task { @MainActor in
            if let url = await neural.synthesize(text), let audioPlayer = try? AVAudioPlayer(contentsOf: url) {
                audioPlayer.delegate = self
                self.player = audioPlayer
                audioPlayer.play()
            } else {
                // Couldn't synthesize — keep isSpeaking and let the system voice finish it.
                self.speak(text, voice: self.resolvedVoice())
            }
        }
    }

    /// Speak a one-line sample in a specific voice, for the picker's Preview.
    func preview(identifier: String) {
        let voice = AVSpeechSynthesisVoice(identifier: identifier) ?? resolvedVoice()
        speak("Hi, I'm here and ready whenever you need me.", voice: voice)
    }

    private func speak(_ text: String, voice: AVSpeechSynthesisVoice?) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        utterance.pitchMultiplier = 1.03
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            if self.isSpeaking {
                self.isSpeaking = false
                self.onFinish?()
            }
        }
    }

    // MARK: - Voice selection

    private static var preferredLanguage: String { Locale.preferredLanguages.first ?? "en-US" }

    private static func option(from voice: AVSpeechSynthesisVoice) -> VoiceOption {
        let quality: VoiceOption.Quality
        switch voice.quality {
        case .premium: quality = .premium
        case .enhanced: quality = .enhanced
        default: quality = .standard
        }
        return VoiceOption(id: voice.identifier, name: voice.name, quality: quality, language: voice.language)
    }

    /// Voices to show in the picker, best first, in the user's language.
    func availableVoices() -> [VoiceOption] {
        VoiceCatalog.ordered(AVSpeechSynthesisVoice.speechVoices().map(Self.option), preferredLanguage: Self.preferredLanguage)
    }

    /// The AVSpeechSynthesisVoice to actually speak with.
    func resolvedVoice() -> AVSpeechSynthesisVoice? {
        let options = AVSpeechSynthesisVoice.speechVoices().map(Self.option)
        if let pick = VoiceCatalog.select(identifier: chosenVoiceID, from: options, preferredLanguage: Self.preferredLanguage),
           let voice = AVSpeechSynthesisVoice(identifier: pick.id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: Self.preferredLanguage)
    }

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
