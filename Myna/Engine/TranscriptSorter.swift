import Foundation
import SwiftData

/// Sorts the transcript into what was real conversation and what was something
/// playing nearby (an audiobook, music, television, a podcast). Everything is
/// kept; each stretch is only labelled, so media can be told apart or hidden.
@MainActor
final class TranscriptSorter {
    static let shared = TranscriptSorter()

    /// Labels a stretch can get. Anything but "conversation" is media.
    static let kinds = ["conversation", "audiobook", "music", "tv", "podcast", "media"]

    static func isMedia(_ context: String) -> Bool { !context.isEmpty && context != "conversation" }

    static func label(_ context: String) -> String {
        switch context {
        case "audiobook": return "Audiobook"
        case "music": return "Music"
        case "tv": return "TV / video"
        case "podcast": return "Podcast / radio"
        case "media": return "Media"
        default: return ""
        }
    }

    private var container: ModelContainer?
    private var generate: ((String, String) async throws -> String)?
    private var loop: Task<Void, Never>?

    private init() {}

    func start(container: ModelContainer, generate: @escaping (String, String) async throws -> String) {
        self.container = container
        self.generate = generate
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(40))
            while !Task.isCancelled {
                await self?.sortPending()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private static let instructions = """
    You sort pieces of a wearable microphone's transcript. Decide what one piece is. \
    Reply with only JSON: {"kind": "...", "title": "..."}
    kind is exactly one of:
    - conversation: real people talking with or near the wearer, the wearer alone, a phone call, a meeting.
    - audiobook: a narrator reading a book or story.
    - music: song lyrics.
    - tv: film, television or video dialogue, news, sports commentary, adverts.
    - podcast: a podcast or radio talk show.
    - media: any other recording being played.
    title is three to six words naming the piece. If unsure, answer conversation.
    """

    /// Label stretches that have finished (a pause after them) or grown long.
    private func sortPending() async {
        guard let container, let generate else { return }
        let context = container.mainContext
        let cutoff = Date().addingTimeInterval(-45)
        var descriptor = FetchDescriptor<Utterance>(
            predicate: #Predicate<Utterance> { $0.context == "" && $0.heardAt < cutoff },
            sortBy: [SortDescriptor(\Utterance.heardAt)]
        )
        descriptor.fetchLimit = 400
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        // Cut into stretches: a gap of two minutes, or thirty lines, ends one.
        var stretches: [[Utterance]] = []
        var current: [Utterance] = []
        for line in pending {
            if let last = current.last,
               line.heardAt.timeIntervalSince(last.heardAt) > 120 || current.count >= 30 {
                stretches.append(current)
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { stretches.append(current) }

        var done = 0
        for stretch in stretches where done < 4 {
            guard let last = stretch.last else { continue }
            let finished = Date().timeIntervalSince(last.heardAt) > 120 || stretch.count >= 30
            guard finished else { continue }
            let words = stretch.reduce(0) { $0 + $1.text.split(separator: " ").count }
            var kind = "conversation"
            var title = ""
            if words >= 15 {
                let text = stretch.map(\.text).joined(separator: "\n")
                guard let raw = try? await generate(Self.instructions, String(text.prefix(3_500))) else {
                    return  // no model available right now; try again later
                }
                (kind, title) = Self.parse(raw)
                done += 1
            }
            for line in stretch {
                line.context = kind
                line.segment = title
            }
            try? context.save()
        }
    }

    static func parse(_ raw: String) -> (String, String) {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(raw[open...close].utf8)) as? [String: Any] else {
            return ("conversation", "")
        }
        let kind = (object["kind"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let title = (object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (kinds.contains(kind) ? kind : "conversation", String(title.prefix(60)))
    }
}
