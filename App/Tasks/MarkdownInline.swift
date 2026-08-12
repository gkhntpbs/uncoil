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
    ///
    /// Called once per visible row per redraw, and a task list redraws for
    /// anything — a keystroke in the search field, a checkbox anywhere in the
    /// project. It used to compile ten regular expressions on every one of
    /// those calls, which is what made scrolling a long list stutter. The
    /// patterns are compiled once now, and an answer already given is not
    /// worked out again.
    static func plain(_ markdown: String) -> String {
        // Nothing to strip is the common case by a wide margin, and it costs
        // one scan to find out rather than ten.
        guard markdown.contains(where: { Self.marks.contains($0) }) else {
            return markdown.trimmingCharacters(in: .whitespaces)
        }
        if let cached = cache.object(forKey: markdown as NSString) {
            return cached as String
        }
        var text = markdown
        text = stripImages(text)
        text = stripLinks(text)
        text = stripCodeSpans(text)
        text = stripEmphasis(text)
        text = stripStrikethrough(text)
        text = stripAutolinks(text)
        let plain = text.trimmingCharacters(in: .whitespaces)
        cache.setObject(plain as NSString, forKey: markdown as NSString)
        return plain
    }

    /// Every character that can begin one of the marks below. A string with
    /// none of them cannot be changed by any of the passes.
    private static let marks: Set<Character> = ["*", "_", "`", "[", "!", "~", "<"]

    /// Bounded on purpose: a project can hold thousands of tasks and this is a
    /// convenience, not a store. `NSCache` also empties itself under pressure.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4096
        return cache
    }()

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

    /// Compiling a pattern costs far more than running it, and these patterns
    /// are fixed. One compile each, for the life of the process.
    private static let compiled = NSCache<NSString, NSRegularExpression>()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = compiled.object(forKey: pattern as NSString) { return cached }
        guard let built = try? NSRegularExpression(pattern: pattern) else { return nil }
        compiled.setObject(built, forKey: pattern as NSString)
        return built
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = regex(pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: template
        )
    }
}
