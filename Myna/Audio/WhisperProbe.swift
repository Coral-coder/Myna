import Foundation
import WhisperKit

/// Temporary smoke-test anchor: an unconditional reference to a WhisperKit type,
/// so CI proves the package resolves and links alongside the existing MLX
/// packages (both pull in swift-transformers) before the real transcription
/// pipeline is built on top. Replaced by `WhisperTranscriber` in this same PR
/// once the dependency graph is confirmed green.
enum WhisperProbe {
    static let frameworkName = String(describing: WhisperKit.self)
}
