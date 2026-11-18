import SwiftData
import SwiftUI

/// Today: the day's numbers, an optional live ticker, and the transcript —
/// searchable, each line tappable to say whose voice it is.
///
/// This view itself watches nothing that changes many times a second; the
/// pieces that do (the header status, the ticker, the battery) are their own
/// small views, so the transcript and the numbers aren't rebuilt per packet.
struct TodayView: View {
    @AppStorage("myna.today.showLive") private var showLive = true
    @State private var search = ""

    var body: some View {
        let dayStart = Calendar.current.startOfDay(for: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TodayHeader()
                TodayStats(dayStart: dayStart)
                TodayCloud(dayStart: dayStart, search: $search)
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $showLive) {
                        Text("LIVE")
                            .font(MynaTheme.mono(11))
                            .tracking(2)
                            .foregroundStyle(MynaTheme.faint)
                    }
                    .tint(MynaTheme.signal)
                    if showLive { LiveTicker() }
                }
                searchField
                TodaySegments(dayStart: dayStart, search: search.trimmingCharacters(in: .whitespaces))
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(MynaTheme.faint)
            TextField("Search everything heard", text: $search)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(MynaTheme.ink)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(MynaTheme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MynaTheme.hair, lineWidth: 1))
    }
}

private struct TodayHeader: View {
    @EnvironmentObject private var pilot: ConversationPilot
    @EnvironmentObject private var listener: SpeechListener
    @EnvironmentObject private var bee: BeeManager

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(MynaTheme.ink)
                Text(status)
                    .font(MynaTheme.mono(11))
                    .foregroundStyle(MynaTheme.faint)
            }
            Spacer()
            if pilot.hasMeaningfulContent {
                Button(action: pilot.composeNow) {
                    Text("Wrap up")
                        .font(MynaTheme.mono(11))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(MynaTheme.ink)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(MynaTheme.hair, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var status: String {
        let date = Date.now.formatted(.dateTime.weekday(.wide).month().day())
        let source: String
        switch bee.pairing {
        case .streaming: source = bee.audioActive ? "bracelet recording" : "bracelet connected"
        case .scanning, .connecting, .provisioning: source = "looking for bracelet"
        case .off: source = listener.isListening ? "iPhone mic" : "not listening"
        default: source = "bracelet needs attention"
        }
        return "\(date) · \(source)"
    }
}

/// What is being heard this instant: a level bar and the words as they are
/// spoken. Used on Today and on the Transcription settings page.
struct LiveTicker: View {
    @EnvironmentObject private var listener: SpeechListener
    @EnvironmentObject private var bee: BeeManager
    @ObservedObject private var lab = TranscriptionLab.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(MynaTheme.hair)
                    Capsule().fill(MynaTheme.signal)
                        .frame(width: max(3, geo.size.width * min(1, listener.audioLevel)))
                }
            }
            .frame(height: 3)

            Text(words)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(hasWords ? MynaTheme.ink : MynaTheme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(5)

            Text(source)
                .font(MynaTheme.mono(10))
                .foregroundStyle(MynaTheme.faint)
        }
    }

    /// The chosen engine's running text when it has some; otherwise Apple's
    /// instant word stream.
    private var raw: String { lab.livePartial.isEmpty ? listener.liveTranscript : lab.livePartial }
    private var hasWords: Bool { !raw.isEmpty }

    private var words: String {
        if raw.isEmpty { return bee.audioActive || listener.isListening ? "Listening…" : "Nothing is being heard." }
        return raw.count > 280 ? "…" + String(raw.suffix(280)) : raw
    }

    private var source: String {
        if !lab.livePartial.isEmpty { return "\(lab.effectiveEngine.name) · live" }
        if !lab.liveStatus.isEmpty { return lab.liveStatus }
        return listener.liveTranscript.isEmpty ? " " : "Apple Speech · preview"
    }
}

/// Today's numbers, where the animated orb used to be.
private struct TodayStats: View {
    @Query private var lines: [Utterance]

    init(dayStart: Date) {
        _lines = Query(filter: #Predicate<Utterance> { $0.heardAt >= dayStart })
    }

    var body: some View {
        let words = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let seconds = lines.reduce(0.0) { $0 + $1.duration }
        let voices = Set(lines.map(\.speakerKey).filter { !$0.isEmpty }).count
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            stat(Self.clock(seconds), "talk heard")
            stat("\(words)", "words")
            stat("\(lines.count)", "segments")
            stat("\(voices)", voices == 1 ? "voice" : "voices")
            NotesStat()
            BatteryStat()
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(MynaTheme.hairSoft).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(MynaTheme.hairSoft).frame(height: 1) }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        TodayStatCell(value: value, label: label)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
    }
}

private struct NotesStat: View {
    @EnvironmentObject private var pilot: ConversationPilot
    var body: some View {
        TodayStatCell(value: "\(pilot.notesComposedToday)", label: pilot.notesComposedToday == 1 ? "note" : "notes")
    }
}

private struct BatteryStat: View {
    @EnvironmentObject private var bee: BeeManager
    var body: some View {
        TodayStatCell(value: bee.batteryLevel.map { "\($0)%" } ?? "—", label: "bracelet")
    }
}

private struct TodayStatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(MynaTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(MynaTheme.mono(10))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(MynaTheme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The transcript: today's lines, or — while searching — matches from any day.
private struct TodaySegments: View {
    @Query private var lines: [Utterance]
    @Query(sort: \VoicePerson.createdAt) private var people: [VoicePerson]
    @State private var openID: UUID?
    @State private var newName = ""
    @AppStorage("myna.today.hideMedia") private var hideMedia = false
    private let searching: Bool

    init(dayStart: Date, search: String) {
        searching = !search.isEmpty
        var descriptor: FetchDescriptor<Utterance>
        if search.isEmpty {
            descriptor = FetchDescriptor(predicate: #Predicate<Utterance> { $0.heardAt >= dayStart },
                                         sortBy: [SortDescriptor(\Utterance.heardAt, order: .reverse)])
            descriptor.fetchLimit = 500
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate<Utterance> { $0.text.localizedStandardContains(search) },
                                         sortBy: [SortDescriptor(\Utterance.heardAt, order: .reverse)])
            descriptor.fetchLimit = 200
        }
        _lines = Query(descriptor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(searching ? "\(lines.count) MATCHES" : "TRANSCRIPT")
                    .font(MynaTheme.mono(11))
                    .tracking(2)
                    .foregroundStyle(MynaTheme.faint)
                Spacer()
                // Audiobooks, music, TV and the like are kept and labelled;
                // this only hides them from the list.
                Button { hideMedia.toggle() } label: {
                    Text(hideMedia ? "MEDIA HIDDEN" : "MEDIA SHOWN")
                        .font(MynaTheme.mono(10))
                        .tracking(1.5)
                        .foregroundStyle(MynaTheme.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            if lines.isEmpty {
                Text(searching ? "Nothing heard matches that." : "Nothing transcribed yet today. Lines appear here as you talk.")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(MynaTheme.muted)
                    .padding(.vertical, 12)
            }

            ForEach(hideMedia ? lines.filter { !TranscriptSorter.isMedia($0.context) } : lines) { line in
                row(line)
                Rectangle().fill(MynaTheme.hairSoft).frame(height: 1)
            }
        }
    }

    private func speakerName(_ line: Utterance) -> String {
        people.first { $0.key == line.speakerKey }?.name ?? ""
    }

    @ViewBuilder
    private func row(_ line: Utterance) -> some View {
        let open = openID == line.id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openID = open ? nil : line.id
                newName = ""
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(line.heardAt.formatted(searching ? .dateTime.month().day().hour().minute() : .dateTime.hour().minute()))
                        .font(MynaTheme.mono(10))
                        .foregroundStyle(MynaTheme.faint)
                        .frame(width: searching ? 86 : 46, alignment: .leading)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 3) {
                        let name = speakerName(line)
                        if !name.isEmpty {
                            Text(name)
                                .font(MynaTheme.mono(10))
                                .tracking(1)
                                .textCase(.uppercase)
                                .foregroundStyle(MynaTheme.muted)
                        }
                        if TranscriptSorter.isMedia(line.context) {
                            Text(line.segment.isEmpty ? TranscriptSorter.label(line.context)
                                 : "\(TranscriptSorter.label(line.context)) · \(line.segment)")
                                .font(MynaTheme.mono(10))
                                .tracking(1)
                                .textCase(.uppercase)
                                .foregroundStyle(MynaTheme.faint)
                        }
                        Text(line.text)
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(TranscriptSorter.isMedia(line.context) ? MynaTheme.muted : MynaTheme.ink)
                            .multilineTextAlignment(.leading)
                            .lineLimit(open ? nil : 3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open { detail(line) }
        }
    }

    /// Shown in place, under the line that was tapped.
    @ViewBuilder
    private func detail(_ line: Utterance) -> some View {
        let current = people.first { $0.key == line.speakerKey }
        VStack(alignment: .leading, spacing: 10) {
            Text("\(line.engine)\(line.duration > 0 ? String(format: " · %.0f s", line.duration) : "")")
                .font(MynaTheme.mono(10))
                .foregroundStyle(MynaTheme.faint)

            if line.embedding == nil {
                Text("No voice print for this line (too short, or the voice model wasn't ready), so it can't be matched to a person.")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(MynaTheme.muted)
            } else {
                Text("WHO SAID THIS?")
                    .font(MynaTheme.mono(10))
                    .tracking(1.5)
                    .foregroundStyle(MynaTheme.faint)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(people) { person in
                            Button {
                                TranscriptionLab.shared.assign(line, to: person)
                            } label: {
                                Text(person.name)
                                    .font(.system(size: 13, weight: person.key == line.speakerKey ? .regular : .light))
                                    .foregroundStyle(person.key == line.speakerKey ? MynaTheme.paper : MynaTheme.ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(person.key == line.speakerKey ? MynaTheme.ink : Color.clear))
                                    .overlay(Capsule().strokeBorder(MynaTheme.hair, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let current {
                    HStack(spacing: 8) {
                        TextField(current.isNamed ? "Rename \(current.name)" : "Name this voice", text: $newName)
                            .font(.system(size: 14, weight: .light))
                            .foregroundStyle(MynaTheme.ink)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MynaTheme.hair, lineWidth: 1))
                        Button {
                            TranscriptionLab.shared.name(current, as: newName)
                            newName = ""
                        } label: {
                            Text("Save")
                                .font(MynaTheme.mono(11))
                                .tracking(1)
                                .textCase(.uppercase)
                                .foregroundStyle(newName.trimmingCharacters(in: .whitespaces).isEmpty ? MynaTheme.faint : MynaTheme.ink)
                        }
                        .buttonStyle(.plain)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .padding(.leading, searching ? 98 : 58)
        .padding(.bottom, 12)
    }
}

/// The words said most today, sized by how often. Tapping one searches for it.
private struct TodayCloud: View {
    @Query private var lines: [Utterance]
    @Binding var search: String

    init(dayStart: Date, search: Binding<String>) {
        _lines = Query(filter: #Predicate<Utterance> { $0.heardAt >= dayStart })
        _search = search
    }

    /// Words too common to say anything about the day.
    private static let dull: Set<String> = [
        "the", "and", "that", "this", "with", "for", "you", "your", "are", "was", "were", "have", "has", "had", "but",
        "not", "they", "them", "their", "there", "then", "than", "what", "when", "where", "which", "who", "how", "why",
        "from", "just", "like", "about", "would", "could", "should", "will", "can", "into", "out", "all", "one", "get",
        "got", "its", "it's", "i'm", "i'll", "i've", "don't", "that's", "yeah", "okay", "know", "going", "want", "really",
        "well", "also", "some", "any", "our", "been", "being", "here", "him", "her", "his", "she", "did", "does", "doing",
        "because", "think", "thing", "things", "right", "more", "very", "much", "over", "only", "even", "still", "these",
        "those", "let", "say", "said", "yes", "gonna", "kind", "sort", "lot", "back", "see", "now", "too", "way", "make",
        "need", "time", "something", "actually", "you're", "we're", "they're", "can't", "didn't", "isn't", "there's",
    ]

    private var words: [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        for line in lines {
            for raw in line.text.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "\u{2019}") }) {
                let word = raw.replacingOccurrences(of: "\u{2019}", with: "'").trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                guard word.count >= 3, !Self.dull.contains(word) else { continue }
                counts[word, default: 0] += 1
            }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(36)
            .map { (word: $0.key, count: $0.value) }
    }

    var body: some View {
        let top = words
        if top.count >= 4 {
            let highest = Double(top.first?.count ?? 1)
            let lowest = Double(top.last?.count ?? 1)
            VStack(alignment: .leading, spacing: 10) {
                Text("WORDS")
                    .font(MynaTheme.mono(11))
                    .tracking(2)
                    .foregroundStyle(MynaTheme.faint)
                CloudLayout(spacing: 10, lineSpacing: 6) {
                    // Alphabetical, so the big words scatter instead of piling up first.
                    ForEach(top.sorted { $0.word < $1.word }, id: \.word) { item in
                        let weight = highest > lowest ? (Double(item.count) - lowest) / (highest - lowest) : 0.5
                        Button {
                            search = item.word
                        } label: {
                            Text(item.word)
                                .font(.system(size: 13 + 17 * weight, weight: .light))
                                .foregroundStyle(weight > 0.5 ? MynaTheme.ink : MynaTheme.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Lays children out left to right, wrapping to new lines; each line is
/// centred on its tallest word's baseline area.
private struct CloudLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index: index, size: size))
            x += size.width + spacing
        }
        return rows.filter { !$0.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let laid = rows(subviews, width: width)
        let height = laid.reduce(CGFloat(0)) { $0 + ($1.map(\.size.height).max() ?? 0) } + lineSpacing * CGFloat(max(0, laid.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}
