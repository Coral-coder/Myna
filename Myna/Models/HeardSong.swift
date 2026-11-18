import Foundation
import SwiftData

/// A song Myna recognised playing nearby.
@Model
final class HeardSong {
    var id: UUID = UUID()
    /// Shazam's identifier for the song; the same song heard again updates
    /// this entry rather than adding another.
    var shazamID: String = ""
    var title: String = ""
    var artist: String = ""
    var appleMusicURL: String = ""
    var artworkURL: String = ""
    var isrc: String = ""
    /// The song's identifier in the Apple Music catalogue, for playlists.
    var appleMusicID: String = ""
    var firstHeard: Date = Date.now
    var lastHeard: Date = Date.now
    var timesHeard: Int = 1

    init(shazamID: String, title: String, artist: String, appleMusicURL: String, artworkURL: String, isrc: String,
         appleMusicID: String = "") {
        self.shazamID = shazamID
        self.title = title
        self.artist = artist
        self.appleMusicURL = appleMusicURL
        self.artworkURL = artworkURL
        self.isrc = isrc
        self.appleMusicID = appleMusicID
    }

    /// A Spotify search for this song (Shazam gives no Spotify link).
    var spotifyURL: URL? {
        let query = "\(title) \(artist)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return URL(string: "https://open.spotify.com/search/\(query)")
    }
}
