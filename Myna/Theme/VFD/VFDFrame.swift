import SwiftUI

/// Text sizes on the VFD grid. Bigger text uses more cells, never bigger cells.
enum VFDSize {
    case small, mid, big

    /// Pixels per glyph pixel of the 5x7 design (1, 2 or 3).
    var scale: Int {
        switch self {
        case .small: return 1
        case .mid: return 2
        case .big: return 3
        }
    }

    /// Cells from one character to the next.
    var advance: Int { 6 * scale }
    /// Cap height in cells.
    var height: Int { 7 * scale }
    /// Glyph width in cells.
    var glyphWidth: Int { 5 * scale }

    var table: [UInt32: [UInt32]] {
        switch self {
        case .small: return VFDGlyphs.small
        case .mid: return VFDGlyphs.mid
        case .big: return VFDGlyphs.big
        }
    }
}

/// The palette: index 0 is an unlit cell; 1-4 the four lit colours; 5+ are
/// the base-colour swatches on the Appearance page.
enum VFDInk {
    static let unlit: UInt8 = 0
    static let base: UInt8 = 1
    static let text: UInt8 = 2
    static let dim: UInt8 = 3
    static let alarm: UInt8 = 4
    static let swatch: UInt8 = 5
}

struct VFDPalette {
    static let amber: UInt32 = 0xFFB014
    static let presets: [(name: String, hex: UInt32)] = [
        ("AMBER", 0xFFB014), ("GREEN", 0x3CFF6E), ("CYAN", 0x3CF0DC),
        ("BLUE", 0x5AA0FF), ("RED", 0xFF4B3C), ("WHITE", 0xF0F0F0),
    ]

    /// Colours by palette index.
    let colors: [Color]

    init(base: UInt32) {
        let (r, g, b) = Self.parts(base)
        let text: UInt32
        let dim: UInt32
        if base == Self.amber {
            text = 0xFFE8C4
            dim = 0x966428
        } else {
            func mix(_ c: Int) -> Int { Int((Double(c) + Double(255 - c) * 0.74).rounded()) }
            func low(_ c: Int) -> Int { min(255, Int((Double(c) * 0.56 + 14).rounded())) }
            text = Self.join(mix(r), mix(g), mix(b))
            dim = Self.join(low(r), low(g), low(b))
        }
        var colors = [Self.color(0x090909), Self.color(base), Self.color(text), Self.color(dim), Self.color(0xFF5028)]
        colors += Self.presets.map { Self.color($0.hex) }
        self.colors = colors
    }

    static func color(_ hex: UInt32) -> Color {
        let (r, g, b) = parts(hex)
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }

    private static func parts(_ hex: UInt32) -> (Int, Int, Int) {
        (Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF))
    }

    private static func join(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }
}

/// A rectangle of cells that runs `action` when tapped.
struct VFDHit {
    let c: Int, r: Int, w: Int, h: Int
    let action: () -> Void

    func contains(_ col: Int, _ row: Int) -> Bool {
        col >= c && col < c + w && row >= r && row < r + h
    }
}

/// The frame buffer: one byte per cell (a palette index, 0 = unlit), and the
/// tap rectangles registered while drawing. Every drawing call works in
/// whole cells.
final class VFDFrame {
    let cols: Int
    let rows: Int
    var cells: [UInt8]
    var hits: [VFDHit] = []
    /// Drawing outside this is dropped: (first column, first row, end column, end row).
    var clip: (Int, Int, Int, Int)

    init(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        cells = [UInt8](repeating: 0, count: self.cols * self.rows)
        clip = (0, 0, self.cols, self.rows)
    }

    // MARK: Cells

    @inline(__always)
    func set(_ c: Int, _ r: Int, _ ink: UInt8) {
        guard c >= clip.0, c < clip.2, r >= clip.1, r < clip.3 else { return }
        cells[r * cols + c] = ink
    }

    func at(_ c: Int, _ r: Int) -> UInt8 {
        guard c >= 0, c < cols, r >= 0, r < rows else { return 0 }
        return cells[r * cols + c]
    }

    func fill(_ c: Int, _ r: Int, _ w: Int, _ h: Int, _ ink: UInt8) {
        let x0 = max(c, clip.0), y0 = max(r, clip.1)
        let x1 = min(c + w, clip.2), y1 = min(r + h, clip.3)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 { cells[y * cols + x] = ink }
        }
    }

    func hline(_ c: Int, _ r: Int, _ w: Int, _ ink: UInt8, step: Int = 1) {
        guard w > 0 else { return }
        for x in stride(from: c, to: c + w, by: max(1, step)) { set(x, r, ink) }
    }

    func vline(_ c: Int, _ r: Int, _ h: Int, _ ink: UInt8, step: Int = 1) {
        guard h > 0 else { return }
        for y in stride(from: r, to: r + h, by: max(1, step)) { set(c, y, ink) }
    }

    func box(_ c: Int, _ r: Int, _ w: Int, _ h: Int, _ ink: UInt8) {
        hline(c, r, w, ink)
        hline(c, r + h - 1, w, ink)
        vline(c, r, h, ink)
        vline(c + w - 1, r, h, ink)
    }

    /// A single-cell line (Bresenham).
    func line(_ c0: Int, _ r0: Int, _ c1: Int, _ r1: Int, _ ink: UInt8) {
        var x = c0, y = r0
        let dx = abs(c1 - c0), dy = -abs(r1 - r0)
        let sx = c0 < c1 ? 1 : -1, sy = r0 < r1 ? 1 : -1
        var err = dx + dy
        while true {
            set(x, y, ink)
            if x == c1 && y == r1 { return }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    /// Registers a tap rectangle (only the part inside the clip).
    func tap(_ c: Int, _ r: Int, _ w: Int, _ h: Int, _ action: @escaping () -> Void) {
        let x0 = max(c, clip.0), y0 = max(r, clip.1)
        let x1 = min(c + w, clip.2), y1 = min(r + h, clip.3)
        guard x0 < x1, y0 < y1 else { return }
        hits.append(VFDHit(c: x0, r: y0, w: x1 - x0, h: y1 - y0, action: action))
    }

    /// The topmost tap rectangle at a cell (the last one registered wins).
    func hit(_ c: Int, _ r: Int) -> VFDHit? {
        hits.last(where: { $0.contains(c, r) })
    }

    // MARK: Text

    static func width(_ text: String, _ size: VFDSize) -> Int {
        let n = text.unicodeScalars.count
        return n == 0 ? 0 : n * size.advance - (size.advance - size.glyphWidth)
    }

    /// Characters that fit in `most` columns.
    static func room(_ most: Int, _ size: VFDSize) -> Int {
        max(0, (most + size.advance - size.glyphWidth) / size.advance)
    }

    /// Draws `text` with its top-left at (c, r); returns the column after it.
    @discardableResult
    func text(_ c: Int, _ r: Int, _ text: String, _ size: VFDSize = .small, _ ink: UInt8 = VFDInk.text) -> Int {
        let table = size.table
        let fallback = table[0x3F] ?? []
        var x = c
        for scalar in text.unicodeScalars {
            let rows = table[scalar.value] ?? fallback
            if x > clip.2 { break }
            for (y, bits) in rows.enumerated() where bits != 0 {
                var b = bits
                var px = 0
                while b != 0 {
                    if b & 1 == 1 { set(x + px, r + y, ink) }
                    b >>= 1
                    px += 1
                }
            }
            x += size.advance
        }
        return x
    }

    @discardableResult
    func textRight(_ right: Int, _ r: Int, _ text: String, _ size: VFDSize = .small, _ ink: UInt8 = VFDInk.text) -> Int {
        let start = right - Self.width(text, size)
        self.text(start, r, text, size, ink)
        return start
    }

    /// Cut short with … to fit in `most` columns.
    static func fitted(_ text: String, _ most: Int, _ size: VFDSize) -> String {
        let room = Self.room(most, size)
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > room else { return text }
        guard room > 1 else { return room == 1 ? "…" : "" }
        var cut = String(String.UnicodeScalarView(scalars[0..<(room - 1)]))
        while cut.hasSuffix(" ") { cut.removeLast() }
        return cut + "…"
    }

    @discardableResult
    func textFit(_ c: Int, _ r: Int, _ text: String, most: Int, _ size: VFDSize = .small,
                 _ ink: UInt8 = VFDInk.text) -> Int {
        self.text(c, r, Self.fitted(text, most, size), size, ink)
    }

    /// The lines `text` wraps to in `most` columns.
    static func wrap(_ text: String, _ most: Int, _ size: VFDSize) -> [String] {
        let room = max(1, Self.room(most, size))
        var out: [String] = []
        var line = ""
        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            var word = String(raw)
            while word.unicodeScalars.count > room {
                if !line.isEmpty { out.append(line); line = "" }
                let scalars = Array(word.unicodeScalars)
                out.append(String(String.UnicodeScalarView(scalars[0..<room])))
                word = String(String.UnicodeScalarView(scalars[room...]))
            }
            if line.isEmpty {
                line = word
            } else if line.unicodeScalars.count + 1 + word.unicodeScalars.count <= room {
                line += " " + word
            } else {
                out.append(line)
                line = word
            }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }

    /// Rows from one wrapped line to the next.
    static func lineStep(_ size: VFDSize, gap: Int) -> Int { size.height + 2 * size.scale + gap }

    /// Word-wrapped text; returns the row below the last line.
    @discardableResult
    func paragraph(_ c: Int, _ r: Int, _ text: String, most: Int, _ size: VFDSize = .small,
                   _ ink: UInt8 = VFDInk.text, gap: Int = 2, lines: Int = 999) -> Int {
        var out = Self.wrap(text, most, size)
        if out.count > lines {
            out = Array(out.prefix(lines))
            out[out.count - 1] = Self.fitted(out[out.count - 1] + " …", most, size)
            if !out[out.count - 1].hasSuffix("…") { out[out.count - 1] += "…" }
        }
        let step = Self.lineStep(size, gap: gap)
        for (i, piece) in out.enumerated() {
            self.text(c, r + i * step, piece, size, ink)
        }
        return r + out.count * step
    }

    // MARK: Composite pieces

    /// A solid block with the text cut out (left unlit). Returns its height.
    @discardableResult
    func inverted(_ c: Int, _ r: Int, _ w: Int, _ text: String, _ size: VFDSize = .small,
                  _ ink: UInt8 = VFDInk.base, pad: Int = 2, center: Bool = false) -> Int {
        let descends = text.contains { "gjpqyµ,;".contains($0) }
        let h = size.height + 2 * pad + (descends ? 2 * size.scale : 0)
        fill(c, r, w, h, ink)
        let shown = Self.fitted(text, w - 2 * (pad + 1), size)
        let tx = center ? c + (w - Self.width(shown, size)) / 2 : c + pad + 1
        self.text(tx, r + pad, shown, size, VFDInk.unlit)
        return h
    }

    static func bracketWidth(_ text: String) -> Int { width(text, .small) + 14 }

    /// An [OPTION] selector, inverted when selected. Returns the column after it.
    @discardableResult
    func bracket(_ c: Int, _ r: Int, _ text: String, selected: Bool, _ ink: UInt8 = VFDInk.text,
                 action: (() -> Void)? = nil) -> Int {
        let tw = Self.width(text, .small)
        let w = tw + 14
        if selected {
            inverted(c, r - 2, w, text, center: true)
        } else {
            self.text(c, r, "[", .small, VFDInk.dim)
            self.text(c + 7, r, text, .small, ink)
            self.text(c + 7 + tw + 2, r, "]", .small, VFDInk.dim)
        }
        if let action { tap(c, r - 3, w, 13, action) }
        return c + w
    }

    /// OFF / ON, right-aligned: the live state inverted, the other dim.
    func toggle(right: Int, _ r: Int, on: Bool, action: @escaping () -> Void) {
        let wOff = Self.width("OFF", .small) + 6, wOn = Self.width("ON", .small) + 6
        let cOn = right - wOn
        let cOff = cOn - 3 - wOff
        if on {
            text(cOff + 3, r, "OFF", .small, VFDInk.dim)
            inverted(cOn, r - 2, wOn, "ON", center: true)
        } else {
            inverted(cOff, r - 2, wOff, "OFF", .small, VFDInk.dim, center: true)
            text(cOn + 3, r, "ON", .small, VFDInk.dim)
        }
        tap(cOff - 4, r - 4, right - cOff + 4, 15, action)
    }

    /// [-] value [+], right-aligned.
    func stepper(right: Int, _ r: Int, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) {
        let plusC = right - Self.width("[+]", .small)
        text(plusC, r, "[+]", .small, VFDInk.base)
        let valueRight = plusC - 6
        textRight(valueRight, r, value, .small, VFDInk.text)
        let minusC = valueRight - max(Self.width(value, .small), 17) - 6 - Self.width("[-]", .small)
        text(minusC, r, "[-]", .small, VFDInk.base)
        tap(minusC - 3, r - 4, Self.width("[-]", .small) + 6, 15, minus)
        tap(plusC - 3, r - 4, Self.width("[+]", .small) + 6, 15, plus)
    }

    /// 6 rows: a dotted dim track, an optional lit target zone, and a solid
    /// LED fill or a 3x6 marker at `value` (0...1).
    func ledBar(_ c: Int, _ r: Int, _ w: Int, value: Double, zone: ClosedRange<Double>? = nil,
                fill solid: Bool = true, _ ink: UInt8 = VFDInk.base) {
        guard w > 3 else { return }
        hline(c, r + 2, w, VFDInk.dim, step: 2)
        hline(c + 1, r + 3, w - 1, VFDInk.dim, step: 2)
        if let zone {
            let a = c + Int(zone.lowerBound * Double(w - 1)), b = c + Int(zone.upperBound * Double(w - 1))
            fill(a, r + 2, b - a + 1, 2, VFDInk.dim)
        }
        let at = c + Int(max(0, min(1, value)) * Double(w - 1))
        if solid {
            for x in c...at where (x - c) % 3 != 2 { vline(x, r + 1, 4, ink) }
        } else {
            fill(min(at - 1, c + w - 3), r, 3, 6, ink)
        }
    }

    /// A single-cell line chart over a dotted dim baseline; values 0...1.
    func chart(_ c: Int, _ r: Int, _ w: Int, _ h: Int, values: [Double], _ ink: UInt8 = VFDInk.base) {
        hline(c, r + h - 1, w, VFDInk.dim, step: 2)
        guard values.count >= 2, w > 1, h > 2 else { return }
        let points = values.enumerated().map { i, v -> (Int, Int) in
            (c + Int((Double(i) * Double(w - 1) / Double(values.count - 1)).rounded()),
             r + h - 2 - Int((max(0, min(1, v)) * Double(h - 2)).rounded()))
        }
        for i in 1..<points.count {
            line(points[i - 1].0, points[i - 1].1, points[i].0, points[i].1, ink)
        }
    }

    /// Copies rows [from, from + count) of `other` (same width) to row `to`
    /// here, and its tap rectangles with them.
    func blit(_ other: VFDFrame, from: Int, count: Int, to: Int) {
        guard other.cols == cols else { return }
        for i in 0..<max(0, count) {
            let src = from + i, dst = to + i
            guard src >= 0, src < other.rows, dst >= 0, dst < rows else { continue }
            let s = src * cols, d = dst * cols
            for x in 0..<cols { cells[d + x] = other.cells[s + x] }
        }
        for hit in other.hits {
            let top = max(hit.r, from), bottom = min(hit.r + hit.h, from + count)
            guard top < bottom else { continue }
            hits.append(VFDHit(c: hit.c, r: top - from + to, w: hit.w, h: bottom - top, action: hit.action))
        }
    }
}
