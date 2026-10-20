import XCTest
@testable import MynaCore

/// The far-field boost that lets Myna hear across a room. These lock in that it
/// lifts quiet speech, never amplifies silence, and never clips out of range.
final class AudioGainTests: XCTestCase {
    /// A quiet, steady tone-ish signal around ±0.05 — a distant voice.
    private func quietSignal(_ count: Int = 1024) -> [Float] {
        (0..<count).map { i in 0.05 * sin(Float(i) * 0.2) }
    }

    func testUnityGainIsNoOp() {
        let signal = quietSignal()
        let gain = AudioGain(gain: 1)
        XCTAssertFalse(gain.isActive)
        XCTAssertEqual(gain.apply(to: signal), signal)
    }

    func testBoostLiftsQuietSpeech() {
        let signal = quietSignal()
        let boosted = AudioGain(gain: 4).apply(to: signal)
        XCTAssertGreaterThan(AudioGain.rms(boosted), AudioGain.rms(signal) * 2,
                             "a 4x boost should make a distant voice clearly louder")
    }

    func testSilenceIsNotAmplified() {
        // Below the noise floor → left exactly as-is, so a quiet room stays quiet.
        let hiss = (0..<1024).map { _ in Float.random(in: -0.001...0.001) }
        let out = AudioGain(gain: 8, noiseFloor: 0.01).apply(to: hiss)
        XCTAssertEqual(out, hiss)
    }

    func testOutputStaysInRange() {
        // Even a loud signal with max boost must not exceed [-1, 1].
        let loud = (0..<1024).map { i in 0.6 * sin(Float(i) * 0.3) }
        for s in AudioGain(gain: 8).apply(to: loud) {
            XCTAssert(s >= -1 && s <= 1, "soft clip must bound the signal, got \(s)")
        }
    }

    func testGainIsClamped() {
        XCTAssertEqual(AudioGain(gain: 100).gain, 8)
        XCTAssertEqual(AudioGain(gain: 0).gain, 1)
    }

    func testSoftClipBounds() {
        XCTAssertEqual(AudioGain.softClip(0), 0, accuracy: 1e-6)
        // Saturates to the [-1, 1] rails, never past them.
        XCTAssertLessThanOrEqual(AudioGain.softClip(10), 1)
        XCTAssertGreaterThanOrEqual(AudioGain.softClip(-10), -1)
        // And compresses rather than passing a boosted peak straight through.
        XCTAssertLessThan(AudioGain.softClip(2), 2)
    }

    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(AudioGain.rms([Float](repeating: 0, count: 256)), 0)
        XCTAssertEqual(AudioGain.rms([]), 0)
    }
}
