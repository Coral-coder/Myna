import Foundation
import MusicKit

/// Makes a playlist in the user's Apple Music library from the songs Myna
/// heard (MusicKit).
enum ApplePlaylist {
    struct Entry: Sendable {
        let appleMusicID: String
        let isrc: String
        let title: String
    }

    /// Creates the playlist and returns a sentence saying what happened.
    static func create(from entries: [Entry]) async -> String {
        let access = await MusicAuthorization.request()
        guard access == .authorized else {
            return "Myna isn't allowed to use Apple Music. Allow it in Settings › Myna › Media & Apple Music."
        }

        var found: [Song] = []
        var missed = 0
        // Songs with a catalogue identifier are looked up together, in order.
        let ids = entries.map(\.appleMusicID).filter { !$0.isEmpty }
        var byID: [String: Song] = [:]
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            start += batch.count
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch.map { MusicItemID($0) })
            do {
                for song in try await request.response().items { byID[song.id.rawValue] = song }
            } catch {
                return "Apple Music couldn't look the songs up: \(error.localizedDescription)"
            }
        }
        for entry in entries {
            if let song = byID[entry.appleMusicID] {
                found.append(song)
            } else if !entry.isrc.isEmpty,
                      let song = try? await MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: entry.isrc)
                        .response().items.first {
                found.append(song)
            } else {
                missed += 1
            }
        }
        guard !found.isEmpty else { return "None of these songs could be found in Apple Music." }

        let name = "Heard by Myna · \(Date().formatted(date: .abbreviated, time: .omitted))"
        do {
            _ = try await MusicLibrary.shared.createPlaylist(
                name: name,
                description: "Songs Myna recognised playing nearby.",
                authorDisplayName: "Myna",
                items: found
            )
        } catch {
            return "Apple Music couldn't create the playlist: \(error.localizedDescription)"
        }
        let skipped = missed > 0 ? " \(missed) couldn't be found in Apple Music." : ""
        return "Created “\(name)” in Apple Music with \(found.count) songs.\(skipped)"
    }
}
