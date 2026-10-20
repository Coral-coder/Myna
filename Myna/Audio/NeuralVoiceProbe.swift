import Foundation
import SherpaOnnx

/// Temporary smoke-test anchor for the on-device neural TTS engine. An
/// unconditional reference to a sherpa-onnx type forces the binary xcframework
/// (and onnxruntime) to resolve, link, and archive for iOS on CI — the dominant
/// risk for a binary dependency. Replaced by `NeuralVoice` once the graph is
/// confirmed green.
enum NeuralVoiceProbe {
    static let engineName = String(describing: SherpaOnnxOfflineTtsWrapper.self)
}
