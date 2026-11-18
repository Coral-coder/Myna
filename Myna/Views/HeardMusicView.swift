import SwiftData
import SwiftUI

/// Memory › Music: the songs Myna recognised playing nearby, newest first,
/// with a way to open each one and to export the list.
struct HeardMusicView: View {
    @Query(sort: \HeardSong.lastHeard, order: .reverse) private var songs: [HeardSong]
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @ObservedObject private var spotter = MusicSpotter.shared
    @AppStorage("myna.music.spot") private var spotting = true

    private var playlistText: String {
        songs.map { song in
            var line = "\(song.title) — \(song.artist)"
            if !song.appleMusicURL.isEmpty { line += "\n\(song.appleMusicURL)" }
            return line
        }.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: $spotting) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recognise music playing nearby")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(MynaTheme.ink)
                        Text(spotter.lastStatus.isEmpty ? "Checked every half minute while there's sound." : spotter.lastStatus)
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(MynaTheme.muted)
                    }
                }
                .tint(MynaTheme.signal)
                .padding(.bottom, 14)

                HStack {
                    Text("\(songs.count) SONGS")
                        .font(MynaTheme.mono(11))
                        .tracking(2)
                        .foregroundStyle(MynaTheme.faint)
                    Spacer()
                    if !songs.isEmpty {
                        ShareLink(item: playlistText) {
                            Text("EXPORT PLAYLIST")
                                .font(MynaTheme.mono(10))
                                .tracking(1.5)
                                .foregroundStyle(MynaTheme.ink)
                        }
                    }
                }
                .padding(.bottom, 8)

                if songs.isEmpty {
                    Text("Nothing recognised yet. Songs appear here when music plays near you.")
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(MynaTheme.muted)
                        .padding(.vertical, 12)
                }

                ForEach(songs) { song in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(song.title)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(MynaTheme.ink)
                        Text(song.artist)
                            .font(.system(size: 14, weight: .light))
                            .foregroundStyle(MynaTheme.muted)
                        HStack(spacing: 14) {
                            Text(song.lastHeard.formatted(date: .abbreviated, time: .shortened)
                                 + (song.timesHeard > 1 ? " · heard \(song.timesHeard) times" : ""))
                                .font(MynaTheme.mono(10))
                                .foregroundStyle(MynaTheme.faint)
                            Spacer()
                            if let url = URL(string: song.appleMusicURL), !song.appleMusicURL.isEmpty {
                                link("Apple Music") { openURL(url) }
                            }
                            if let url = song.spotifyURL {
                                link("Spotify") { openURL(url) }
                            }
                            link("Remove") {
                                context.delete(song)
                                try? context.save()
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    Rectangle().fill(MynaTheme.hairSoft).frame(height: 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(MynaTheme.mono(10))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(MynaTheme.ink)
        }
        .buttonStyle(.plain)
    }
}
