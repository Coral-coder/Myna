import AVFoundation
import Foundation
import SoundAnalysis

/// Listens for what is going on around the user besides talk — music, rain,
/// traffic, a dog, a doorbell — using Apple's built-in sound classifier, and
/// keeps a short memory of it for the assistant.
final class AmbientListener: NSObject, SNResultsObserving, @unchecked Sendable {
    static let shared = AmbientListener()

    private let queue = DispatchQueue(label: "myna.ambient", qos: .utility)
    private var analyzer: SNAudioStreamAnalyzer?
    private var format: AVAudioFormat?
    private var position: AVAudioFramePosition = 0

    private let lock = NSLock()
    private var heard: [(label: String, at: Date)] = []

    /// Not worth noting: talk is the transcript's job.
    private static let ignored: Set<String> = ["speech", "silence", "breathing", "inside_small_room", "inside_large_room"]

    func ingest(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            if analyzer == nil || format != buffer.format { start(buffer.format) }
            analyzer?.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func start(_ newFormat: AVAudioFormat) {
        let stream = SNAudioStreamAnalyzer(format: newFormat)
        if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            request.overlapFactor = 0
            try? stream.add(request, withObserver: self)
        }
        analyzer = stream
        format = newFormat
        position = 0
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let top = result.classifications.first(where: { !Self.ignored.contains($0.identifier) }),
              top.confidence > 0.7 else { return }
        let label = top.identifier.replacingOccurrences(of: "_", with: " ")
        lock.lock()
        defer { lock.unlock() }
        // The same sound carrying on isn't news; note it once a minute.
        if let last = heard.last(where: { $0.label == label }), Date().timeIntervalSince(last.at) < 60 { return }
        heard.append((label, Date()))
        if heard.count > 300 { heard.removeFirst(heard.count - 300) }
    }

    /// The distinct sounds of the last `minutes`, most recent first.
    func recent(minutes: Double = 15) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var seen: [String] = []
        for entry in heard.reversed() where Date().timeIntervalSince(entry.at) < minutes * 60 {
            if !seen.contains(entry.label) { seen.append(entry.label) }
        }
        return seen
    }
}
