import SwiftData
import SwiftUI
import UIKit

/// Cell geometry for this screen: 5 device pixels per cell on 3x screens,
/// 4 on 2x, so every cell lines up with whole device pixels.
struct VFDMetrics {
    let scale: CGFloat
    let pitch: Int
    /// Cell size in points.
    let cell: CGFloat
    let cols: Int
    let rows: Int
    /// Rows left empty for the status bar and the home indicator.
    let top: Int
    let bottom: Int

    init(size: CGSize, scale: CGFloat, insets: UIEdgeInsets) {
        self.scale = max(1, scale)
        pitch = self.scale >= 3 ? 5 : 4
        cell = CGFloat(pitch) / self.scale
        cols = max(1, Int((size.width * self.scale) / CGFloat(pitch)))
        rows = max(1, Int((size.height * self.scale) / CGFloat(pitch)))
        top = Int((insets.top * self.scale / CGFloat(pitch)).rounded(.up)) + 1
        bottom = Int((insets.bottom * self.scale / CGFloat(pitch)).rounded(.up)) + 1
    }
}

/// Columns and fixed rows, proportional to the width so screens work at
/// about 241 cells (3x) and 207 (2x).
struct VFDLayout {
    static let headerRows = 22
    static let tabRows = 15
    static let inputRows = 18

    let cols: Int
    let margin: Int
    let top: Int
    /// First row of the bottom safe area.
    let bottom: Int
    let bodyTop: Int
    let bodyBottom: Int

    init(cols: Int, top: Int, bottom: Int, input: Bool) {
        self.cols = cols
        margin = max(4, Int((Double(cols) * 0.03).rounded()))
        self.top = top
        self.bottom = bottom
        bodyTop = top + Self.headerRows
        bodyBottom = bottom - Self.tabRows - (input ? Self.inputRows : 0)
    }

    var left: Int { margin }
    var right: Int { cols - margin }
    var width: Int { right - left }
    /// A column at a fraction of the usable width.
    func col(_ fraction: Double) -> Int { left + Int((Double(width) * fraction).rounded()) }
}

/// Holds the last drawn frame for touch handling between renders.
final class VFDTouchState {
    var frame: VFDFrame?
    var maxScroll = 0
}

/// The Amber VFD look: the whole screen is one dot-matrix grid, drawn by
/// immediate-mode screens into a frame buffer and painted by one Canvas.
struct VFDRootView: View {
    enum Tab: String, CaseIterable { case ask = "ASK", today = "TODAY", memory = "MEMORY", settings = "SETTINGS" }
    enum MemoryList: String, CaseIterable { case notes = "NOTES", memories = "MEMORIES", lists = "LISTS" }

    enum Sheet: Identifiable {
        case transcription, server, general, models, today, note(ConversationNote)
        var id: String {
            switch self {
            case .note(let note): return "note-\(note.id.uuidString)"
            case .transcription: return "transcription"
            case .server: return "server"
            case .general: return "general"
            case .models: return "models"
            case .today: return "today"
            }
        }
    }

    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var pilot: ConversationPilot
    @EnvironmentObject private var bee: BeeManager
    @EnvironmentObject private var brain: MynaBrain
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var lab = TranscriptionLab.shared
    @ObservedObject private var server = HomeServer.shared
    @ObservedObject private var log = ChatLog.shared

    @Query private var lines: [Utterance]
    @Query(sort: \VoicePerson.createdAt) private var people: [VoicePerson]
    @Query private var notes: [ConversationNote]
    @Query private var memories: [Memory]
    @Query private var items: [MynaItem]

    @State private var tab: Tab = .today
    @State private var memoryList: MemoryList = .notes
    @State private var appearanceOpen = false
    @State private var scroll: [String: Int] = [:]
    @State private var stickToEnd = true
    @State private var dragStart: Int?
    @State private var sheet: Sheet?
    @State private var asking = false
    @State private var draft = ""
    @State private var sending = false
    @State private var touch = VFDTouchState()

    @AppStorage("myna.vfd.unlit") private var showUnlit = true
    @AppStorage("myna.vfd.clock24") private var clock24 = true
    @AppStorage("myna.vfd.lines") private var transcriptLines = 60
    @AppStorage(TranscriptionLab.serverOnlyKey) private var serverOnly = false

    private let suggestions = [
        "What did I say I'd do today?",
        "Summarize my last conversation",
        "What have I been thinking about lately?",
        "What's on my calendar this week?",
    ]

    init() {
        var u = FetchDescriptor<Utterance>(sortBy: [SortDescriptor(\Utterance.heardAt, order: .reverse)])
        u.fetchLimit = 2000
        _lines = Query(u)
        var n = FetchDescriptor<ConversationNote>(sortBy: [SortDescriptor(\ConversationNote.startedAt, order: .reverse)])
        n.fetchLimit = 100
        _notes = Query(n)
        var m = FetchDescriptor<Memory>(predicate: #Predicate<Memory> { $0.archived == false },
                                        sortBy: [SortDescriptor(\Memory.createdAt, order: .reverse)])
        m.fetchLimit = 200
        _memories = Query(m)
        var i = FetchDescriptor<MynaItem>(sortBy: [SortDescriptor(\MynaItem.createdAt, order: .reverse)])
        i.fetchLimit = 300
        _items = Query(i)
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let m = VFDMetrics(size: geo.size, scale: displayScale, insets: Self.windowInsets)
                let frame = render(m, now: timeline.date)
                let palette = VFDPalette(base: themeStore.vfdBase)
                let unlit = showUnlit
                Canvas(opaque: true) { context, size in
                    Self.paint(context, size: size, frame: frame, metrics: m, palette: palette, showUnlit: unlit)
                }
                .gesture(drag(m))
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .sheet(item: $sheet) { which in sheetView(which) }
        .alert("Ask Myna", isPresented: $asking) {
            TextField("Ask anything", text: $draft)
            Button("Send") { send(draft) }
            Button("Cancel", role: .cancel) { draft = "" }
        }
    }

    // MARK: - Painting

    private static var tiles: [Int: UIImage] = [:]

    /// One cell of the unlit grid: a #090909 square with a 1-pixel black gap.
    private static func tile(_ m: VFDMetrics) -> UIImage {
        if let cached = tiles[m.pitch * 10 + Int(m.scale)] { return cached }
        let format = UIGraphicsImageRendererFormat()
        format.scale = m.scale
        format.opaque = true
        let size = CGSize(width: m.cell, height: m.cell)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 9 / 255, green: 9 / 255, blue: 9 / 255, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: m.cell - 1 / m.scale, height: m.cell - 1 / m.scale))
        }
        tiles[m.pitch * 10 + Int(m.scale)] = image
        return image
    }

    private static func paint(_ context: GraphicsContext, size: CGSize, frame: VFDFrame, metrics m: VFDMetrics,
                              palette: VFDPalette, showUnlit: Bool) {
        let all = Path(CGRect(origin: .zero, size: size))
        context.fill(all, with: .color(.black))
        if showUnlit {
            context.fill(all, with: .tiledImage(Image(uiImage: tile(m)), origin: .zero,
                                                sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), scale: 1))
        }
        let dot = m.cell - 1 / m.scale
        var paths = [Path](repeating: Path(), count: palette.colors.count)
        for r in 0..<frame.rows {
            let row = r * frame.cols
            let y = CGFloat(r) * m.cell
            for c in 0..<frame.cols {
                let ink = Int(frame.cells[row + c])
                guard ink > 0, ink < paths.count else { continue }
                paths[ink].addRect(CGRect(x: CGFloat(c) * m.cell, y: y, width: dot, height: dot))
            }
        }
        for ink in 1..<paths.count where !paths[ink].isEmpty {
            context.fill(paths[ink], with: .color(palette.colors[ink]))
        }
    }

    private static var windowInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.safeAreaInsets ?? .zero
    }

    // MARK: - Touch

    private var screenKey: String {
        switch tab {
        case .memory: return "memory.\(memoryList.rawValue)"
        case .settings: return appearanceOpen ? "settings.appearance" : "settings"
        default: return tab.rawValue
        }
    }

    private func drag(_ m: VFDMetrics) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                if dragStart == nil {
                    guard abs(g.translation.height) > 6 else { return }
                    dragStart = current(scrollFor: screenKey)
                }
                let moved = Int((g.translation.height / m.cell).rounded())
                let target = max(0, min(touch.maxScroll, (dragStart ?? 0) - moved))
                scroll[screenKey] = target
                if tab == .ask { stickToEnd = target >= touch.maxScroll }
            }
            .onEnded { g in
                defer { dragStart = nil }
                guard dragStart == nil else { return }
                let c = Int(g.location.x / m.cell), r = Int(g.location.y / m.cell)
                touch.frame?.hit(c, r)?.action()
            }
    }

    private func current(scrollFor key: String) -> Int {
        if tab == .ask && stickToEnd { return touch.maxScroll }
        return min(scroll[key] ?? 0, touch.maxScroll)
    }

    // MARK: - Rendering

    private func render(_ m: VFDMetrics, now: Date) -> VFDFrame {
        let f = VFDFrame(cols: m.cols, rows: m.rows)
        let L = VFDLayout(cols: m.cols, top: m.top, bottom: m.rows - m.bottom, input: tab == .ask)
        let content = VFDFrame(cols: m.cols, rows: 4000)
        let used: Int
        switch tab {
        case .today: used = drawToday(content, L, now: now)
        case .ask: used = drawAsk(content, L, now: now)
        case .memory: used = drawMemory(content, L, now: now)
        case .settings: used = appearanceOpen ? drawAppearance(content, L, now: now) : drawSettings(content, L)
        }
        let viewport = max(1, L.bodyBottom - L.bodyTop)
        let maxScroll = max(0, min(content.rows, used) - viewport)
        let offset = (tab == .ask && stickToEnd) ? maxScroll : min(scroll[screenKey] ?? 0, maxScroll)
        f.blit(content, from: offset, count: viewport, to: L.bodyTop)
        if maxScroll > 0 {
            // A thin dim scroll marker on the right edge.
            let length = max(4, viewport * viewport / max(1, used))
            let at = L.bodyTop + (viewport - length) * offset / max(1, maxScroll)
            f.vline(m.cols - 2, at, length, VFDInk.dim)
        }
        header(f, L, now: now)
        if tab == .ask { inputRow(f, L) }
        tabBar(f, L)
        touch.frame = f
        touch.maxScroll = maxScroll
        return f
    }

    // MARK: - Chrome

    private func header(_ f: VFDFrame, _ L: VFDLayout, now: Date) {
        let r = L.top + 4
        var c = L.left
        let title: String
        switch tab {
        case .today: title = "TODAY"
        case .ask: title = "ASK"
        case .memory: title = "MEMORY"
        case .settings: title = appearanceOpen ? "APPEARANCE" : "SETTINGS"
        }
        if tab == .settings && appearanceOpen {
            let end = f.text(c, r + 4, "< BACK", .small, VFDInk.base)
            f.tap(L.left - 2, L.top, end - L.left + 6, VFDLayout.headerRows - 1) { appearanceOpen = false }
            c = end + 6
        }
        f.text(c, r, title, .mid, VFDInk.text)
        switch tab {
        case .today:
            let start = f.textRight(L.right, r + 4, "[FULL]", .small, VFDInk.base)
            f.tap(start - 3, L.top, L.right - start + 6, VFDLayout.headerRows - 1) { sheet = .today }
            f.textRight(start - 8, r + 4, Self.dayLabel(now), .small, VFDInk.dim)
        case .ask:
            if !log.messages.isEmpty {
                let start = f.textRight(L.right, r + 4, "[NEW CHAT]", .small, VFDInk.base)
                f.tap(start - 3, L.top, L.right - start + 6, VFDLayout.headerRows - 1) {
                    log.clear()
                    stickToEnd = true
                }
            }
        case .memory:
            f.textRight(L.right, r + 4, "\(notes.count + memories.count) SAVED", .small, VFDInk.dim)
        case .settings:
            break
        }
        f.hline(0, L.top + VFDLayout.headerRows - 1, f.cols, VFDInk.dim, step: 2)
    }

    private func tabBar(_ f: VFDFrame, _ L: VFDLayout) {
        let r = L.bottom - VFDLayout.tabRows
        f.fill(0, r, f.cols, VFDLayout.tabRows, VFDInk.unlit)
        f.hline(0, r, f.cols, VFDInk.dim, step: 2)
        let slot = Double(L.right - L.left + 4) / Double(Tab.allCases.count)
        for (i, item) in Tab.allCases.enumerated() {
            let x0 = L.left - 2 + Int((Double(i) * slot).rounded())
            let x1 = L.left - 2 + Int((Double(i + 1) * slot).rounded())
            if item == tab {
                f.inverted(x0 + 2, r + 3, x1 - x0 - 4, item.rawValue, center: true)
            } else {
                f.text(x0 + (x1 - x0 - VFDFrame.width(item.rawValue, .small)) / 2, r + 5, item.rawValue, .small, VFDInk.dim)
            }
            f.tap(x0, r, x1 - x0, VFDLayout.tabRows) {
                if tab == item, item == .settings { appearanceOpen = false }
                tab = item
            }
        }
    }

    private func inputRow(_ f: VFDFrame, _ L: VFDLayout) {
        let r = L.bodyBottom + 3
        f.fill(0, L.bodyBottom, f.cols, VFDLayout.inputRows, VFDInk.unlit)
        let sendW = VFDFrame.width("SEND", .small) + 10
        f.box(L.left, r, L.width - sendW - 3, 13, VFDInk.dim)
        f.textFit(L.left + 4, r + 3, sending ? "Thinking…" : "Ask Myna…", most: L.width - sendW - 11, .small, VFDInk.dim)
        f.inverted(L.right - sendW, r, sendW, "SEND", pad: 3, center: true)
        f.tap(L.left, r - 2, L.width, 17) { if !sending { asking = true } }
    }

    // MARK: - Shared pieces

    /// A dim label with a dotted rule after it; returns the row below.
    @discardableResult
    private func section(_ f: VFDFrame, _ L: VFDLayout, _ r: Int, _ label: String, right: String? = nil,
                         rightInk: UInt8 = VFDInk.dim) -> Int {
        let end = f.text(L.left, r, label, .small, VFDInk.dim)
        var ruleEnd = L.right
        if let right { ruleEnd = f.textRight(L.right, r, right, .small, rightInk) - 4 }
        f.hline(end + 3, r + 3, ruleEnd - end - 3, VFDInk.dim, step: 2)
        return r + 12
    }

    private func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = clock24 ? "HH:mm" : "h:mm"
        return f.string(from: date)
    }

    private static func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: date).uppercased()
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: date).uppercased()
    }

    private var names: [String: String] {
        Dictionary(people.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Today

    private func drawToday(_ f: VFDFrame, _ L: VFDLayout, now: Date) -> Int {
        let dayStart = Calendar.current.startOfDay(for: now)
        let today = lines.filter { $0.heardAt >= dayStart }
        let who = names
        var r = 3

        let listening = pilot.phase == .listening
        var parts = [pilot.phase == .composing ? "WRITING A NOTE" : (listening ? "LISTENING" : "NOT LISTENING")]
        if bee.pairing == .streaming { parts.append("BRACELET") }
        parts.append(server.reachable == true ? "HOME SERVER" : "PHONE ONLY")
        var banner = parts.joined(separator: " · ")
        if VFDFrame.width(banner, .small) > L.width - 6 { banner = banner.replacingOccurrences(of: "HOME SERVER", with: "SERVER") }
        r += f.inverted(L.left, r, L.width, banner, .small, listening ? VFDInk.base : VFDInk.dim, center: true) + 5

        // Hero readouts; the labels carry the units.
        let c2 = L.col(0.56)
        let words = today.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let voices = Set(today.map(\.speakerKey).filter { !$0.isEmpty }).count
        f.textFit(L.left, r, "WORDS TODAY", most: c2 - L.left - 6, .small, VFDInk.dim)
        f.text(c2, r, "SPEAKING NOW", .small, VFDInk.dim)
        f.textFit(L.left, r + 11, Self.grouped(words), most: c2 - L.left - 4, .big, VFDInk.base)
        var speaking = "QUIET"
        if let last = today.first, now.timeIntervalSince(last.heardAt) < 90 {
            speaking = (who[last.speakerKey] ?? "").uppercased()
            if speaking.isEmpty { speaking = "SOMEONE" }
        }
        f.textFit(c2, r + 11, speaking, most: L.right - c2, .mid, speaking == "QUIET" ? VFDInk.dim : VFDInk.text)
        f.text(c2, r + 28, "\(voices) VOICE\(voices == 1 ? "" : "S") TODAY", .small, VFDInk.dim)
        r += 11 + 21 + 8

        // Bracelet and phone panel.
        let boxH = 41
        f.box(L.left, r, L.width, boxH, VFDInk.dim)
        let cols = [L.left + 4, L.col(0.33), L.col(0.64), L.right - 4]
        let battery = bee.batteryLevel
        let cells: [(String, String, UInt8)] = [
            ("BATTERY %", battery.map(String.init) ?? "--", (battery ?? 100) < 20 ? VFDInk.alarm : VFDInk.base),
            ("NEW NOTES", "\(pilot.notesComposedToday)", VFDInk.text),
            ("HELD CLIPS", "\(lab.heldCount)", VFDInk.text),
        ]
        for (i, cell) in cells.enumerated() {
            f.textFit(cols[i], r + 3, cell.0, most: cols[i + 1] - cols[i] - 4, .small, VFDInk.dim)
            f.textFit(cols[i], r + 13, cell.1, most: cols[i + 1] - cols[i] - 4, .mid, cell.2)
        }
        f.ledBar(L.left + 4, r + boxH - 10, L.width - 8, value: Double(battery ?? 0) / 100,
                 fill: true, (battery ?? 100) < 20 ? VFDInk.alarm : VFDInk.base)
        r += boxH + 6

        // Minutes of speech per hour, last 12 hours.
        r = section(f, L, r, "SPEECH MIN / HOUR", right: "LAST 12 H")
        let hourStart = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        var minutes = [Double](repeating: 0, count: 13)
        for line in lines {
            let back = Int(hourStart.timeIntervalSince(line.heardAt) / 3600 + 1)
            let index = line.heardAt >= hourStart ? 12 : 12 - back
            if index < 0 { break }
            minutes[index] += max(line.duration, 2) / 60
        }
        let peak = max(5, minutes.max() ?? 0)
        f.chart(L.left, r, L.width, 26, values: minutes.map { $0 / peak })
        let hours = DateFormatter()
        hours.dateFormat = clock24 ? "HH" : "ha"
        for i in 0..<5 {
            let at = hourStart.addingTimeInterval(Double(i * 3 - 12) * 3600)
            let label = hours.string(from: at).lowercased()
            let x = L.left + Int((Double(i) * Double(L.width - 1) / 4).rounded())
            if i == 0 { f.text(x, r + 28, label, .small, VFDInk.dim) }
            else if i == 4 { f.textRight(L.right, r + 28, label, .small, VFDInk.dim) }
            else { f.text(x - VFDFrame.width(label, .small) / 2, r + 28, label, .small, VFDInk.dim) }
        }
        r += 28 + 13

        // Transcript, newest first.
        let live = !lab.livePartial.isEmpty
        r = section(f, L, r, "TRANSCRIPT", right: live ? "LIVE" : "\(today.count) LINES", rightInk: live ? VFDInk.base : VFDInk.dim)
        let textC = L.col(0.25)
        if live {
            f.text(L.left, r, "NOW", .small, VFDInk.base)
            r = f.paragraph(textC, r, lab.livePartial, most: L.right - textC, .small, VFDInk.base) + 5
        }
        if today.isEmpty && !live {
            f.text(L.left, r, "Nothing heard yet today.", .small, VFDInk.dim)
            r += 12
        }
        for line in today.prefix(max(10, transcriptLines)) {
            let media = !line.context.isEmpty && line.context != "conversation"
            let start = r
            f.text(L.left, r, clock(line.heardAt), .small, VFDInk.dim)
            let label = media ? line.context.uppercased() : (who[line.speakerKey] ?? "").uppercased()
            f.textFit(L.left, r + 10, label.isEmpty ? "—" : label, most: textC - L.left - 4, .small,
                      media ? VFDInk.dim : VFDInk.base)
            r = max(f.paragraph(textC, r, line.text, most: L.right - textC, .small, media ? VFDInk.dim : VFDInk.text),
                    r + 20) + 5
            f.tap(L.left, start, L.width, r - start) { sheet = .today }
        }
        return r + 4
    }

    // MARK: - Ask

    private func drawAsk(_ f: VFDFrame, _ L: VFDLayout, now: Date) -> Int {
        var r = 4
        if log.messages.isEmpty {
            r = f.paragraph(L.left, r, "Your memory, on call. Ask about anything you've talked about.",
                            most: L.width, .small, VFDInk.text) + 6
            r = section(f, L, r, "TRY")
            for s in suggestions {
                let start = r
                r = f.paragraph(L.left + 12, r, s, most: L.width - 12, .small, VFDInk.base) + 4
                f.text(L.left, start, "→", .small, VFDInk.dim)
                f.tap(L.left, start - 2, L.width, r - start) { send(s) }
            }
            return r
        }
        for message in log.messages.suffix(80) {
            if message.role == .me {
                let w = Int(Double(L.width) * 0.74)
                let c = L.right - w
                let rows = VFDFrame.wrap(message.text, w - 8, .small).count
                let h = rows * VFDFrame.lineStep(.small, gap: 2) + 6
                f.box(c, r, w, h, VFDInk.dim)
                f.paragraph(c + 4, r + 4, message.text, most: w - 8, .small, VFDInk.text)
                r += h + 6
            } else {
                f.text(L.left, r, "MYNA", .small, VFDInk.base)
                f.text(L.left + 30, r, clock(message.at), .small, VFDInk.dim)
                r += 11
                r = f.paragraph(L.left, r, message.text, most: Int(Double(L.width) * 0.94), .small, VFDInk.text) + 6
            }
        }
        if sending {
            let dots = String(repeating: ".", count: Int(now.timeIntervalSince1970) % 4)
            f.text(L.left, r, "MYNA IS THINKING" + dots, .small, VFDInk.base)
            r += 12
        }
        return r + 4
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !trimmed.isEmpty, !sending else { return }
        log.add(.me, trimmed)
        sending = true
        stickToEnd = true
        Task {
            let reply = await brain.handleTyped(trimmed)
            await MainActor.run {
                sending = false
                log.add(.myna, reply.isEmpty ? "…" : reply)
                stickToEnd = true
            }
        }
    }

    // MARK: - Memory

    private func drawMemory(_ f: VFDFrame, _ L: VFDLayout, now: Date) -> Int {
        var r = 5
        var c = L.left
        for list in MemoryList.allCases {
            c = f.bracket(c, r, list.rawValue, selected: list == memoryList, action: { memoryList = list }) + 3
        }
        r += 15
        switch memoryList {
        case .notes: return drawNotes(f, L, r, now: now)
        case .memories: return drawMemories(f, L, r)
        case .lists: return drawLists(f, L, r)
        }
    }

    private func drawNotes(_ f: VFDFrame, _ L: VFDLayout, _ top: Int, now: Date) -> Int {
        var r = top
        if notes.isEmpty {
            f.paragraph(L.left, r, "No notes yet. Conversations are written up here as they end.", most: L.width, .small, VFDInk.dim)
            return r + 24
        }
        let dayStart = Calendar.current.startOfDay(for: now)
        for note in notes {
            let start = r
            let when = note.startedAt >= dayStart ? clock(note.startedAt) : Self.shortDate(note.startedAt)
            f.text(L.left, r, when, .small, VFDInk.dim)
            let place = note.placeName.uppercased()
            f.textRight(L.right, r, place.isEmpty ? "\(note.durationMinutes) MIN" : VFDFrame.fitted(place, L.width / 2, .small),
                        .small, VFDInk.base)
            r += 11
            r = f.paragraph(L.left, r, note.title.isEmpty ? "Conversation" : note.title, most: L.width, .mid,
                            VFDInk.text, gap: 1, lines: 2) + 2
            if !note.overview.isEmpty {
                r = f.paragraph(L.left, r, note.overview, most: L.width, .small, VFDInk.dim, lines: 2)
            }
            let open = note.actionItems.filter { !$0.isDone }.count
            if open > 0 {
                f.text(L.left, r, "\(open) TO DO", .small, VFDInk.base)
                r += 11
            }
            r += 2
            f.hline(L.left, r, L.width, VFDInk.dim, step: 2)
            r += 6
            f.tap(L.left, start, L.width, r - start) { sheet = .note(note) }
        }
        return r
    }

    private func drawMemories(_ f: VFDFrame, _ L: VFDLayout, _ top: Int) -> Int {
        var r = top
        if memories.isEmpty {
            f.paragraph(L.left, r, "Nothing remembered yet.", most: L.width, .small, VFDInk.dim)
            return r + 14
        }
        f.paragraph(L.left, r, "Tap a memory to confirm it's true.", most: L.width, .small, VFDInk.dim)
        r += 14
        for memory in memories {
            let start = r
            f.text(L.left, r, memory.category.title.uppercased(), .small, VFDInk.dim)
            if memory.pinned { f.textRight(L.right, r, "✓ CONFIRMED", .small, VFDInk.base) }
            r += 11
            r = f.paragraph(L.left, r, memory.content, most: L.width, .small, VFDInk.text) + 2
            f.hline(L.left, r, L.width, VFDInk.dim, step: 2)
            r += 6
            f.tap(L.left, start, L.width, r - start) {
                memory.pinned.toggle()
                try? modelContext.save()
            }
        }
        return r
    }

    private func drawLists(_ f: VFDFrame, _ L: VFDLayout, _ top: Int) -> Int {
        var r = top
        if items.isEmpty {
            f.paragraph(L.left, r, "Nothing on your lists.", most: L.width, .small, VFDInk.dim)
            return r + 14
        }
        for kind in ItemKind.allCases {
            let mine = items.filter { $0.kind == kind }
            guard !mine.isEmpty else { continue }
            let open = mine.filter { !$0.isDone }
            r = section(f, L, r, kind.title.uppercased(), right: "\(open.count) OPEN")
            for item in open + mine.filter(\.isDone).prefix(5) {
                let start = r
                f.text(L.left, r, item.isDone ? "[✓]" : "[ ]", .small, item.isDone ? VFDInk.dim : VFDInk.base)
                r = f.paragraph(L.left + 22, r, item.text, most: L.width - 22, .small,
                                item.isDone ? VFDInk.dim : VFDInk.text) + 3
                f.tap(L.left, start - 2, L.width, r - start + 1) {
                    item.isDone.toggle()
                    item.completedAt = item.isDone ? .now : nil
                    try? modelContext.save()
                }
            }
            r += 4
        }
        return r
    }

    // MARK: - Settings

    private func drawSettings(_ f: VFDFrame, _ L: VFDLayout) -> Int {
        var r = 4
        let rows: [(String, String, () -> Void)] = [
            ("APPEARANCE", "Amber VFD or the standard look; base colour; display.", { appearanceOpen = true }),
            ("TRANSCRIPTION", "Choose, download and test the speech engine.", { sheet = .transcription }),
            ("HOME SERVER", "Send the heavy work to your computer at home.", { sheet = .server }),
            ("LISTENING & BRACELET", "Microphone, Bee bracelet, voices, automation, diagnostics.", { sheet = .general }),
            ("AI MODELS", "The on-device language models Myna thinks with.", { sheet = .models }),
        ]
        for (title, blurb, action) in rows {
            let start = r
            f.text(L.left, r, title, .small, VFDInk.text)
            f.textRight(L.right, r, "→", .small, VFDInk.base)
            r += 11
            r = f.paragraph(L.left, r, blurb, most: L.width - 10, .small, VFDInk.dim, lines: 2) + 2
            f.hline(L.left, r, L.width, VFDInk.dim, step: 4)
            r += 6
            f.tap(L.left, start - 2, L.width, r - start) { action() }
        }
        r += 4
        r = section(f, L, r, "STATUS")
        let pairing: String
        switch bee.pairing {
        case .streaming: pairing = "STREAMING"
        case .off: pairing = "OFF"
        case .scanning: pairing = "SEARCHING"
        case .connecting, .provisioning: pairing = "CONNECTING"
        case .bluetoothOff: pairing = "BLUETOOTH OFF"
        case .unauthorized: pairing = "NOT ALLOWED"
        case .needsFactoryReset: pairing = "NEEDS RESET"
        case .audioUnavailable, .error: pairing = "ERROR"
        }
        let status: [(String, String, UInt8)] = [
            ("HOME SERVER", server.reachable == true ? "CONNECTED" : (server.isPaired ? "AWAY" : "NOT PAIRED"),
             server.reachable == true ? VFDInk.base : VFDInk.dim),
            ("SERVER MS", server.latencyMs.map(String.init) ?? "--", VFDInk.text),
            ("BRACELET", pairing, pairing == "STREAMING" ? VFDInk.base : (pairing == "ERROR" ? VFDInk.alarm : VFDInk.dim)),
            ("SPEECH ENGINE", lab.effectiveEngine.name.uppercased(), VFDInk.text),
        ]
        for (label, value, ink) in status {
            f.text(L.left, r, label, .small, VFDInk.dim)
            f.textRight(L.right, r, VFDFrame.fitted(value, L.width / 2, .small), .small, ink)
            r += 12
        }
        return r + 4
    }

    private func drawAppearance(_ f: VFDFrame, _ L: VFDLayout, now: Date) -> Int {
        var r = 4
        r = section(f, L, r, "THEME")
        var c = L.left
        c = f.bracket(c, r, "STANDARD", selected: themeStore.look == .standard, action: { themeStore.look = .standard }) + 5
        f.bracket(c, r, "AMBER VFD", selected: themeStore.look == .vfd, action: { themeStore.look = .vfd })
        r += 16

        r = section(f, L, r, "BASE COLOR")
        let perRow = 3
        let cellW = L.width / perRow
        for (i, preset) in VFDPalette.presets.enumerated() {
            let x = L.left + (i % perRow) * cellW
            let y = r + (i / perRow) * 16
            f.fill(x, y, 7, 7, VFDInk.swatch + UInt8(i))
            if preset.hex == themeStore.vfdBase {
                f.inverted(x + 10, y - 2, VFDFrame.width(preset.name, .small) + 6, preset.name, center: true)
            } else {
                f.text(x + 13, y, preset.name, .small, VFDInk.text)
            }
            f.tap(x - 2, y - 4, cellW, 15) { themeStore.vfdBase = preset.hex }
        }
        r += 2 * 16 + 4
        f.text(L.left, r, "SAMPLE READOUT", .small, VFDInk.dim)
        f.text(L.left, r + 11, clock(now), .big, VFDInk.base)
        f.text(L.col(0.56), r + 11, "LIVE", .mid, VFDInk.text)
        f.text(L.col(0.56), r + 28, "LABEL · UNIT", .small, VFDInk.dim)
        r += 11 + 21 + 6
        let second = Double(Calendar.current.component(.second, from: now)) / 59
        f.ledBar(L.left, r, L.width, value: second, fill: true)
        r += 12

        r = section(f, L, r, "DISPLAY")
        func row(_ label: String) {
            f.text(L.left, r, label, .small, VFDInk.text)
        }
        func next() {
            r += 15
            f.hline(L.left, r - 4, L.width, VFDInk.dim, step: 4)
        }
        row("SHOW UNLIT CELLS")
        f.toggle(right: L.right, r, on: showUnlit) { showUnlit.toggle() }
        next()
        row("SERVER ONLY")
        f.toggle(right: L.right, r, on: serverOnly) { serverOnly.toggle() }
        next()
        row("TRANSCRIPT LINES")
        f.stepper(right: L.right, r, value: "\(transcriptLines)",
                  minus: { transcriptLines = max(20, transcriptLines - 20) },
                  plus: { transcriptLines = min(400, transcriptLines + 20) })
        next()
        row("CLOCK")
        let w = VFDFrame.bracketWidth("12 H") + VFDFrame.bracketWidth("24 H") + 4
        let c12 = f.bracket(L.right - w, r, "12 H", selected: !clock24, action: { clock24 = false }) + 4
        f.bracket(c12, r, "24 H", selected: clock24, action: { clock24 = true })
        next()
        r += 2
        r = f.paragraph(L.left, r, "The whole screen is one grid of cells. Bigger text uses more cells, never bigger ones.",
                        most: L.width, .small, VFDInk.dim)
        return r + 4
    }

    // MARK: - Screens not yet drawn on the grid

    @ViewBuilder
    private func sheetView(_ which: Sheet) -> some View {
        let services = AppServices.shared
        NavigationStack {
            Group {
                switch which {
                case .transcription: TranscriptionLabView()
                case .server: HomeServerView()
                case .general: SettingsView()
                case .models: ModelHubView()
                case .today: TodayView()
                case .note(let note): NoteDetailView(note: note)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { sheet = nil } }
            }
        }
        .environmentObject(themeStore)
        .environmentObject(services.modelManager)
        .environmentObject(services.listener)
        .environmentObject(services.pilot)
        .environmentObject(services.brain)
        .environmentObject(services.contextHub)
        .environmentObject(services.bee)
        .environmentObject(services.beeCloud)
        .environmentObject(services.whisper)
        .environmentObject(services.neuralVoice)
    }
}
