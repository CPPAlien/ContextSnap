import AppKit
import SwiftUI

/// Lightweight block-level Markdown renderer for chat replies.
///
/// SwiftUI's `Text` only understands inline Markdown, so headings, lists,
/// fenced code and tables come out as flat text. This splits the source
/// into blocks first and renders each with a dedicated view, delegating
/// inline styling (bold / italic / code / links) to `AttributedString`.
struct MarkdownView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.parse(source).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

indirect enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case bulletList([String])
    case orderedList(start: Int, items: [String])
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flushParagraph(_ buf: inout [String]) {
            let text = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            buf.removeAll()
        }

        var para: [String] = []
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushParagraph(&para)
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1 // closing fence
                blocks.append(.code(language: lang.isEmpty ? nil : lang, text: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph(&para); i += 1; continue
            }

            // Heading
            if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph(&para)
                let level = trimmed[m].filter { $0 == "#" }.count
                blocks.append(.heading(level: level, text: String(trimmed[m.upperBound...])))
                i += 1; continue
            }

            // Horizontal rule
            if trimmed.range(of: #"^([-*_])\s*(\1\s*){2,}$"#, options: .regularExpression) != nil {
                flushParagraph(&para); blocks.append(.rule); i += 1; continue
            }

            // Table: header row followed by a separator row like |---|---|
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}"#, options: .regularExpression) != nil {
                flushParagraph(&para)
                let header = splitTableRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(splitTableRow(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushParagraph(&para)
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(q.joined(separator: "\n")))
                continue
            }

            // Bullet list
            if trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil {
                flushParagraph(&para)
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let m = t.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                        items.append(String(t[m.upperBound...]))
                    } else if !t.isEmpty, lines[i].hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += "\n" + t  // continuation line
                    } else { break }
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Ordered list
            if let m = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph(&para)
                let start = Int(trimmed[m].filter(\.isNumber)) ?? 1
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let m = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                        items.append(String(t[m.upperBound...]))
                    } else if !t.isEmpty, lines[i].hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1] += "\n" + t
                    } else { break }
                    i += 1
                }
                blocks.append(.orderedList(start: start, items: items))
                continue
            }

            para.append(line)
            i += 1
        }
        flushParagraph(&para)
        return blocks
    }

    private static func splitTableRow(_ row: String) -> [String] {
        var r = row
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineText(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            InlineText(text).lineSpacing(3)
        case .code(let language, let text):
            CodeBlock(language: language, code: text)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        InlineText(item).lineSpacing(3)
                    }
                }
            }
            .padding(.leading, 4)
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + idx).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)
                        InlineText(item).lineSpacing(3)
                    }
                }
            }
            .padding(.leading, 4)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                InlineText(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

/// Renders inline Markdown (bold, italic, `code`, links, ~~strike~~).
private struct InlineText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(attributed)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var attr = try? AttributedString(markdown: text, options: opts) else {
            return AttributedString(text)
        }
        // Style inline code spans (system parser tags them but doesn't style).
        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].font = .system(.body, design: .monospaced)
            attr[run.range].backgroundColor = Color.primary.opacity(0.08)
        }
        return attr
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))

            Text(code)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let cols = header.count
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        cell(header[c]).font(.callout.weight(.semibold))
                    }
                }
                .background(Color.primary.opacity(0.06))
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            cell(c < row.count ? row[c] : "")
                        }
                    }
                    .background(idx % 2 == 1 ? Color.primary.opacity(0.03) : .clear)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))
    }

    private func cell(_ text: String) -> some View {
        InlineText(text)
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
