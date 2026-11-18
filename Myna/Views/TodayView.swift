import SwiftData
import SwiftUI

/// Today: the day's numbers, an optional live ticker, and the transcript —
/// searchable, each line tappable to say whose voice it is.
struct TodayView: View {
    @EnvironmentObject private var pilot: ConversationPilot
    @EnvironmentObject private var listener: SpeechListener
    @EnvironmentObject private var bee: BeeManager
    @ObservedObject private var lab = TranscriptionLab.shared

    @AppStorage("myna.today.showLive") private var showLive = true
    @State private var search = ""

    private var dayStart: Date { Calendar.current.startOfDay(for: .now) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                TodayStats(dayStart: dayStart, notesToday: pilot.notesComposedToday, battery: bee.batteryLevel)
                liveSection
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

    // MARK: - Header

    private var header: some View {
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

    // MARK: - Live ticker

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $showLive) {
                Text("LIVE")
                    .font(MynaTheme.mono(11))
                    .tracking(2)
                    .foregroundStyle(MynaTheme.faint)
            }
            .tint(MynaTheme.signal)

            if showLive {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MynaTheme.hair)
                        Capsule().fill(MynaTheme.signal)
                            .frame(width: max(3, geo.size.width * min(1, listener.audioLevel)))
                    }
                }
                .frame(height: 3)

                Text(ticker)
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(listener.liveTranscript.isEmpty ? MynaTheme.faint : MynaTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(4)

                if !lab.liveStatus.isEmpty {
                    Text(lab.liveStatus)
                        .font(MynaTheme.mono(10))
                        .foregroundStyle(MynaTheme.faint)
                }
            }
        }
    }

    /// The tail of what is being heard right now.
    private var ticker: String {
        let text = listener.liveTranscript
        if text.isEmpty { return bee.audioActive || listener.isListening ? "Listening…" : "Nothing is being heard." }
        return text.count > 240 ? "…" + String(text.suffix(240)) : text
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

/// Today's numbers, where the animated orb used to be.
private struct TodayStats: View {
    @Query private var lines: [Utterance]
    let notesToday: Int
    let battery: Int?

    init(dayStart: Date, notesToday: Int, battery: Int?) {
        _lines = Query(filter: #Predicate<Utterance> { $0.heardAt >= dayStart })
        self.notesToday = notesToday
        self.battery = battery
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
            stat("\(notesToday)", notesToday == 1 ? "note" : "notes")
            stat(battery.map { "\($0)%" } ?? "—", "bracelet")
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(MynaTheme.hairSoft).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(MynaTheme.hairSoft).frame(height: 1) }
    }

    private func stat(_ value: String, _ label: String) -> some View {
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

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
    }
}

/// The transcript: today's lines, or — while searching — matches from any day.
private struct TodaySegments: View {
    @Query private var lines: [Utterance]
    @Query(sort: \VoicePerson.createdAt) private var people: [VoicePerson]
    @State private var openID: UUID?
    @State private var newName = ""
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
            Text(searching ? "\(lines.count) MATCHES" : "TRANSCRIPT")
                .font(MynaTheme.mono(11))
                .tracking(2)
                .foregroundStyle(MynaTheme.faint)
                .padding(.bottom, 8)

            if lines.isEmpty {
                Text(searching ? "Nothing heard matches that." : "Nothing transcribed yet today. Lines appear here as you talk.")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(MynaTheme.muted)
                    .padding(.vertical, 12)
            }

            ForEach(lines) { line in
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
                        Text(line.text)
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(MynaTheme.ink)
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
