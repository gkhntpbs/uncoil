import Foundation

/// The block structure of an agent's reply.
///
/// SwiftUI reads inline markdown — emphasis, code spans, links — but not
/// blocks, so a reply's headings, lists and code fences would arrive as one
/// run of text with the fences showing. This splits the blocks out and leaves
/// each block's inline markup to `AttributedString`.
///
/// It is written for text that is still arriving: a fence that has not closed
/// yet is a code block already, so a streaming reply does not flash as prose
/// and then jump into a code box when the closing fence lands.
enum ChatMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `marker` is the list's own bullet or number, kept as written.
        case listItem(marker: String, text: String, depth: Int)
        case code(language: String?, text: String)
        case quote(String)
        /// A table is shown as its source, in a fixed-width face, where its
        /// columns still line up.
        case table(String)
        case rule
    }

    static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [String] = []
        var fence: (marker: String, language: String?, lines: [String])?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
            if !table.isEmpty {
                blocks.append(.table(table.joined(separator: "\n")))
                table = []
            }
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = fence {
                if trimmed.hasPrefix(open.marker), trimmed.allSatisfy({ $0 == open.marker.first }) {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = String(trimmed.prefix { $0 == trimmed.first })
                let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                fence = (marker, language.isEmpty ? nil : language, [])
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                table.append(trimmed)
                continue
            }
            if !table.isEmpty { flush() }
            if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                continue
            }
            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flush()
                blocks.append(item)
                continue
            }
            if !quote.isEmpty { flush() }
            // A line under a list item, indented, continues that item.
            if paragraph.isEmpty, line.hasPrefix("  "),
               case .listItem(let marker, let text, let depth)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, text: text + "\n" + trimmed, depth: depth)
                continue
            }
            paragraph.append(trimmed)
        }
        if let open = fence {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> Block? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)
        let depth = min(indent / 2, 4)
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            return .listItem(marker: "•", text: body.dropFirst(2).trimmingCharacters(in: .whitespaces), depth: depth)
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return .listItem(
            marker: "\(digits)\(punctuation)",
            text: afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces),
            depth: depth
        )
    }

    /// Inline markup read into an attributed string; the text as written when
    /// it does not parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
