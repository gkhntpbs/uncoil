import Foundation

/// Strips Markdown's inline marks for display.
///
/// `TODO.md` belongs to the user, so the marks stay in the file: a task written
/// as `**Ship the importer**` keeps its asterisks on disk and in every prompt an
/// agent receives. They just have no business being drawn in a list row, where
/// they read as noise rather than as emphasis.
///
/// Deliberately not a Markdown renderer. It removes the marks around text and
/// leaves the text; nothing is re-styled, because a task row has one type style
/// and emphasis inside it would fight the row, not help it.
enum MarkdownInline {
    /// The task text as it should appear in the interface.
    static func plain(_ markdown: String) -> String {
        var text = markdown
        text = stripImages(text)
        text = stripLinks(text)
        text = stripCodeSpans(text)
        text = stripEmphasis(text)
        text = stripStrikethrough(text)
        text = stripAutolinks(text)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `![alt](src)` → `alt`. Done before links, because an image *is* a link
    /// with a bang in front of it.
    private static func stripImages(_ text: String) -> String {
        replace(text, pattern: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")
    }

    /// `[label](url)` → `label`, and `[label][ref]` → `label`.
    private static func stripLinks(_ text: String) -> String {
        var out = replace(text, pattern: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1")
        out = replace(out, pattern: #"\[([^\]]*)\]\[[^\]]*\]"#, with: "$1")
        return out
    }

    /// `` `code` `` → `code`. Backticks come off after links so a link whose
    /// label is code still resolves to the label.
    private static func stripCodeSpans(_ text: String) -> String {
        replace(text, pattern: #"(`+)([^`]|[^`][\s\S]*?[^`])\1"#, with: "$2")
    }

    /// `**bold**`, `__bold__`, `*italic*`, `_italic_`, and the `***both***`
    /// case, innermost last so nesting unwinds.
    private static func stripEmphasis(_ text: String) -> String {
        var out = text
        for pattern in [
            #"\*\*\*([\s\S]+?)\*\*\*"#,
            #"___([\s\S]+?)___"#,
            #"\*\*([\s\S]+?)\*\*"#,
            #"__([\s\S]+?)__"#,
            // A single mark needs a non-space neighbour, so "2 * 3 * 4" and a
            // snake_case_name are left alone.
            #"(?<![\w*])\*(?![\s*])([\s\S]*?[^\s*])\*(?![\w*])"#,
            #"(?<![\w_])_(?![\s_])([\s\S]*?[^\s_])_(?![\w_])"#,
        ] {
            out = replace(out, pattern: pattern, with: "$1")
        }
        return out
    }

    private static func stripStrikethrough(_ text: String) -> String {
        replace(text, pattern: #"~~([\s\S]+?)~~"#, with: "$1")
    }

    /// `<https://example.com>` → `https://example.com`. Bare angle brackets
    /// around anything else are left alone: they may be literal text.
    private static func stripAutolinks(_ text: String) -> String {
        replace(text, pattern: #"<((?:https?|mailto):[^>\s]+)>"#, with: "$1")
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: template
        )
    }
}
