import Foundation

/// Lifts quiet, distant speech before it reaches the speech recognizer, so Myna
/// can hear someone across a room — not just the person holding the phone.
///
/// The iPhone won't let apps raise the hardware mic gain, so we boost in
/// software: gate out near-silence (so a quiet room's hiss isn't amplified into
/// phantom words), apply linear gain, then soft-clip so the lifted signal
/// saturates smoothly instead of clicking. Kept free of AVFoundation so the math
/// is unit-tested off-device; `SpeechListener` applies the identical steps in
/// place on the live mic buffer.
struct AudioGain {
    /// Multiplier on the signal. 1 = off (unity); higher hears farther. 1...8.
    let gain: Float
    /// Buffers quieter than this RMS are treated as silence and left untouched.
    let noiseFloor: Float

    init(gain: Float, noiseFloor: Float = 0.004) {
        self.gain = min(max(gain, 1), 8)
        self.noiseFloor = max(noiseFloor, 0)
    }

    /// Whether this actually changes the signal (unity gain is a no-op).
    var isActive: Bool { gain > 1.001 }

    /// RMS energy of a buffer, ~0 (silence) to ~1 (loud).
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// tanh soft clip: linear for small signals, saturates smoothly toward ±1 —
    /// no hard edges, so boosted peaks don't turn into clicks the recognizer hates.
    static func softClip(_ x: Float) -> Float { tanhf(x) }

    /// A gained copy of `samples`. No-op at unity gain or below the noise floor,
    /// so silence and room hiss are never amplified into false speech.
    func apply(to samples: [Float]) -> [Float] {
        guard isActive, !samples.isEmpty, Self.rms(samples) >= noiseFloor else { return samples }
        let g = gain
        return samples.map { Self.softClip($0 * g) }
    }
}
