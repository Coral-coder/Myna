import Foundation
import SwiftData

/// One thing somebody said, as transcribed: the unit of the Today transcript.
/// Kept forever so the transcript can be searched.
@Model
final class Utterance {
    var id: UUID = UUID()
    var heardAt: Date = Date.now
    var text: String = ""
    /// Seconds of audio this covers (0 when unknown).
    var duration: Double = 0
    /// The engine that produced the text.
    var engine: String = ""
    /// `VoicePerson.key` of whoever said it, or "" when the voice wasn't identified.
    var speakerKey: String = ""
    /// The voice print of this utterance, so it can be re-assigned later.
    var embedding: Data?

    init(text: String, heardAt: Date, duration: Double, engine: String, speakerKey: String, embedding: Data?) {
        self.text = text
        self.heardAt = heardAt
        self.duration = duration
        self.engine = engine
        self.speakerKey = speakerKey
        self.embedding = embedding
    }
}

/// A voice Myna can recognize. Starts as "Speaker N" the first time a new voice
/// is heard; gets a real name when you tell Myna who it is.
@Model
final class VoicePerson {
    var key: String = UUID().uuidString
    var name: String = ""
    var createdAt: Date = Date.now
    /// Average voice print across everything attributed to this person.
    var centroid: Data = Data()
    var sampleCount: Int = 0
    var isNamed: Bool = false

    init(name: String, centroid: Data) {
        self.name = name
        self.centroid = centroid
        self.sampleCount = 1
    }
}

/// Voice-print maths, kept apart from storage.
enum VoicePrint {
    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(_ data: Data) -> [Float] {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
    }

    /// Cosine similarity, -1...1. 0 when the vectors can't be compared.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na * nb).squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    /// Folds one more sample into a running average.
    static func merged(_ centroid: [Float], count: Int, with sample: [Float]) -> [Float] {
        guard centroid.count == sample.count, count > 0 else { return sample }
        let n = Float(min(count, 200))
        var out = centroid
        for i in 0..<out.count { out[i] = (out[i] * n + sample[i]) / (n + 1) }
        return out
    }
}
