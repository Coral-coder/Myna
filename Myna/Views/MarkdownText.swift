import SwiftUI
import UIKit

/// Renders one of Myna's answers as Markdown — the way the words are written:
/// paragraphs with **bold**, *italic* and `inline code`, headings, bullet and
/// numbered lists, block quotes, tables, and fenced code blocks with a Copy
/// button. The server already sends Markdown; this makes it read like it should
/// instead of as one flat run of text.
struct MarkdownText: View {
    let text: String
    var tint: Color = MynaTheme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                row(block)
            }
        }
        .foregroundStyle(tint.opacity(0.92))
    }

    @ViewBuilder private func row(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            inline(s)
        case .heading(let level, let s):
            inline(s).font(.system(size: level <= 1 ? 20 : level == 2 ? 17 : 15,
                                   weight: .semibold, design: .rounded))
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(tint.opacity(0.6))
                        inline(items[i])
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(tint.opacity(0.6))
                            .font(.system(size: 15, design: .rounded).monospacedDigit())
                        inline(items[i])
                    }
                }
            }
        case .quote(let s):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(MynaTheme.cyan.opacity(0.5)).frame(width: 3)
                inline(s).foregroundStyle(tint.opacity(0.75))
            }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .table(let rows):
            MarkdownTable(rows: rows, tint: tint)
        }
    }

    /// A line of text with inline Markdown (bold, italic, inline code, links).
    /// Returns Text so callers can still apply a heading font; colour is set once
    /// on the whole view.
    private func inline(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return Text(attributed).font(.system(size: 15, design: .rounded))
        }
        return Text(string).font(.system(size: 15, design: .rounded))
    }
}

// MARK: - Fenced code

private struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(MynaTheme.ink.opacity(0.45))
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(copied ? MynaTheme.cyan : MynaTheme.ink.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) { Rectangle().fill(MynaTheme.ink.opacity(0.08)).frame(height: 1) }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(MynaTheme.ink.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MynaTheme.void.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MynaTheme.ink.opacity(0.1)))
    }
}

// MARK: - Tables

private struct MarkdownTable: View {
    let rows: [[String]]
    var tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        cell(rows[r][c], header: r == 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if c < rows[r].count - 1 {
                            Rectangle().fill(MynaTheme.ink.opacity(0.08)).frame(width: 1)
                        }
                    }
                }
                if r < rows.count - 1 {
                    Rectangle().fill(MynaTheme.ink.opacity(0.08)).frame(height: 1)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MynaTheme.ink.opacity(0.1)))
    }

    private func cell(_ text: String, header: Bool) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let content = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return Text(content)
            .font(.system(size: 13, weight: header ? .semibold : .regular, design: .rounded))
            .foregroundStyle(tint.opacity(header ? 0.95 : 0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
    }
}

// MARK: - Parsing

enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case bullet([String])
    case numbered([String])
    case quote(String)
    case code(language: String, code: String)
    case table([[String]])
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block ``` … ```
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                i += 1  // skip the closing fence
                blocks.append(.code(language: language, code: body.joined(separator: "\n")))
                continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Table: a row of | … | followed by a |---|---| separator.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                var tableRows: [[String]] = [splitRow(trimmed)]
                i += 2  // header + separator
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    tableRows.append(splitRow(lines[i])); i += 1
                }
                blocks.append(.table(normalize(tableRows)))
                continue
            }

            // Heading
            if let heading = headingOf(trimmed) {
                flushParagraph(); blocks.append(heading); i += 1; continue
            }

            // Block quote (join consecutive > lines)
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: " ")))
                continue
            }

            // Bullet list
            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            // Numbered list
            if isNumbered(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isNumbered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripNumber(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingOf(_ line: String) -> MarkdownBlock? {
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard level > 0, level <= 6, line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
        return .heading(level, String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }
    private static func stripBullet(_ line: String) -> String {
        String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    private static func isNumbered(_ line: String) -> Bool {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }
    private static func stripNumber(_ line: String) -> String {
        let digits = line.prefix { $0.isNumber }
        return String(line.dropFirst(digits.count + 2)).trimmingCharacters(in: .whitespaces)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }
    private static func splitRow(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    /// Pad every row to the widest, so the grid is rectangular.
    private static func normalize(_ rows: [[String]]) -> [[String]] {
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: max(0, width - $0.count)) }
    }
}
