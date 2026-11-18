import Foundation
import SherpaOnnx

/// Turns a stretch of speech into a voice print (speaker embedding), on device,
/// with a small WeSpeaker model run by sherpa-onnx.
actor VoiceID {
    static let shared = VoiceID()

    private static let modelName = "wespeaker_en_voxceleb_resnet34.onnx"
    private static let modelURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx")!
    /// The published size, used to reject a truncated download.
    private static let minimumBytes: Int64 = 20_000_000

    private var extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper?
    private var downloading = false

    private static var modelFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("MynaLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(modelName)
    }

    private static var modelInstalled: Bool {
        let size = ((try? FileManager.default.attributesOfItem(atPath: modelFile.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return size >= minimumBytes
    }

    /// Fetch the 26 MB model if it isn't here yet. Safe to call repeatedly.
    func prepare() async {
        guard !Self.modelInstalled, !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            let (tmp, response) = try await URLSession.shared.download(from: Self.modelURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
            try? FileManager.default.removeItem(at: Self.modelFile)
            try FileManager.default.moveItem(at: tmp, to: Self.modelFile)
        } catch {
            // Try again on the next launch; transcription works without it.
        }
    }

    /// The voice print for this audio, or nil when the model isn't ready or the
    /// audio is too short to tell voices apart (under about a second).
    func embedding(samples: [Float], sampleRate: Int) -> [Float]? {
        guard Self.modelInstalled, samples.count >= sampleRate else { return nil }
        if extractor == nil {
            var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: Self.modelFile.path, numThreads: 2)
            let created = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
            guard created.impl != nil else { return nil }
            extractor = created
        }
        guard let extractor else { return nil }
        let stream = extractor.createStream()
        stream.acceptWaveform(samples: samples, sampleRate: sampleRate)
        stream.inputFinished()
        let vector = extractor.compute(stream: stream)
        return vector.isEmpty ? nil : vector
    }
}
