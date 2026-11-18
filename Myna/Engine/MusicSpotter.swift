import AVFoundation
import Foundation
import ShazamKit
import SwiftData

/// Recognises music playing nearby, the way Shazam does, from the same audio
/// Myna is already hearing. Every half minute it takes the last twelve seconds
/// and asks Shazam's catalogue; a match goes on the heard-music list.
@MainActor
final class MusicSpotter: ObservableObject {
    static let shared = MusicSpotter()

    @Published private(set) var lastStatus = ""

    private var container: ModelContainer?
    private var samples: [Float] = []
    private var rate: Double = 16_000
    private var sinceLastTry = 0
    private var busy = false

    private static let windowSeconds = 12.0
    private static let everySeconds = 30.0

    private init() {}

    func attach(container: ModelContainer) {
        self.container = container
    }

    /// Takes in the audio Myna hears (mono).
    func ingest(_ data: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard UserDefaults.standard.object(forKey: "myna.music.spot") as? Bool ?? true else { return }
        if sampleRate != rate {
            rate = sampleRate
            samples.removeAll()
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
        let keep = Int(rate * Self.windowSeconds)
        if samples.count > keep { samples.removeFirst(samples.count - keep) }
        sinceLastTry += count
        guard !busy, samples.count >= keep, Double(sinceLastTry) >= rate * Self.everySeconds else { return }
        sinceLastTry = 0

        // Don't ask about silence.
        var sum: Float = 0
        for value in samples { sum += value * value }
        guard (sum / Float(samples.count)).squareRoot() > 0.001 else { return }

        let window = samples
        let windowRate = rate
        busy = true
        Task { [weak self] in
            let found = await Self.identify(window, sampleRate: windowRate)
            guard let self else { return }
            self.busy = false
            switch found {
            case .song(let song):
                self.remember(song)
            case .nothing:
                break
            case .failed(let message):
                self.lastStatus = message
            }
        }
    }

    struct Song: Sendable {
        let shazamID: String
        let title: String
        let artist: String
        let appleMusicURL: String
        let artworkURL: String
        let isrc: String
        let appleMusicID: String
    }

    enum Outcome: Sendable {
        case song(Song)
        case nothing
        case failed(String)
    }

    private nonisolated static func identify(_ samples: [Float], sampleRate: Double) async -> Outcome {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return .nothing }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        do {
            let generator = SHSignatureGenerator()
            try generator.append(buffer, at: nil)
            let signature = generator.signature()
            let session = SHSession()
            switch await session.result(from: signature) {
            case .match(let match):
                guard let item = match.mediaItems.first, let title = item.title, !title.isEmpty else { return .nothing }
                return .song(Song(shazamID: item.shazamID ?? "\(title)|\(item.artist ?? "")",
                                  title: title,
                                  artist: item.artist ?? "",
                                  appleMusicURL: item.appleMusicURL?.absoluteString ?? "",
                                  artworkURL: item.artworkURL?.absoluteString ?? "",
                                  isrc: item.isrc ?? "",
                                  appleMusicID: item.appleMusicID ?? ""))
            case .noMatch:
                return .nothing
            case .error(let error, _):
                return .failed("Music recognition: \(error.localizedDescription)")
            }
        } catch {
            return .failed("Music recognition: \(error.localizedDescription)")
        }
    }

    private func remember(_ song: Song) {
        guard let context = container?.mainContext else { return }
        let key = song.shazamID
        let existing = try? context.fetch(FetchDescriptor<HeardSong>(predicate: #Predicate<HeardSong> { $0.shazamID == key })).first
        if let existing {
            // The same song still playing isn't a new listen.
            if Date().timeIntervalSince(existing.lastHeard) > 600 { existing.timesHeard += 1 }
            existing.lastHeard = .now
            if existing.appleMusicID.isEmpty { existing.appleMusicID = song.appleMusicID }
        } else {
            context.insert(HeardSong(shazamID: song.shazamID, title: song.title, artist: song.artist,
                                     appleMusicURL: song.appleMusicURL, artworkURL: song.artworkURL, isrc: song.isrc,
                                     appleMusicID: song.appleMusicID))
        }
        try? context.save()
        lastStatus = "Heard \(song.title) — \(song.artist)"
    }
}
