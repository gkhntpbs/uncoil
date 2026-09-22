import Foundation

/// One thing a driver needs in order to work, and whether it has it.
struct DriverRequirement: Equatable, Identifiable, Sendable {
    let name: String
    /// `nil` when the driver named the requirement but said nothing decisive
    /// about it — reporting "unknown" is honest; guessing "granted" is not.
    let isGranted: Bool?

    var id: String { name }
}

/// Reads a driver's own status output and says what it means.
///
/// `cua-driver permissions status` answers in ticks and crosses, and that text
/// used to be put on screen exactly as it arrived — emoji, padding and all —
/// which is neither Uncoil's voice nor legible at a glance. The output is a
/// fact to be read, not a thing to display, so it is parsed here and the
/// settings page renders the result in its own furniture.
///
/// Deliberately tolerant: an external tool is free to reword its output, and
/// the cost of failing to parse a line is one row the page does not draw, never
/// a wrong answer. Anything it cannot read decisively comes back as `nil`.
enum DriverReport {
    /// Glyphs a CLI uses to mean yes or no, and the words that go with them.
    private static let granted: Set<String> = [
        "✓", "✔", "✅", "☑", "granted", "authorized", "authorised", "enabled",
        "allowed", "ok", "yes", "true", "on",
    ]
    private static let refused: Set<String> = [
        "✗", "✘", "❌", "✖", "☐", "denied", "missing", "disabled", "blocked",
        "no", "false", "off", "notgranted", "notdetermined", "unknown",
    ]

    static func requirements(in text: String) -> [DriverRequirement] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            requirement(in: String($0))
        }
    }

    /// A single line. The shapes seen in the wild are `✓ Accessibility`,
    /// `Accessibility: granted` and `- screen recording .... denied`, so the
    /// verdict is looked for in the glyph, in the value after a colon, and in
    /// the last word, in that order.
    static func requirement(in line: String) -> DriverRequirement? {
        var rest = line.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }

        var verdict: Bool?
        if let first = rest.first, let leading = decide(String(first)) {
            verdict = leading
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // Bullets and dashes carry no verdict; they are just list furniture.
        while let first = rest.first, "-*•·".contains(first) {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        var name = rest
        if let colon = rest.firstIndex(of: ":") {
            name = String(rest[rest.startIndex..<colon])
            let value = String(rest[rest.index(after: colon)...])
            if let stated = decide(value) { verdict = stated }
        } else if verdict == nil, let last = rest.split(separator: " ").last,
                  let stated = decide(String(last)) {
            verdict = stated
            name = rest.dropLast(last.count).trimmingCharacters(in: .whitespaces)
        }

        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .…-\t"))
        // A line with no verdict at all is prose — a heading, a hint, a blank
        // separator — and inventing a row for it would fill the page with the
        // tool's paragraphs.
        guard verdict != nil, !name.isEmpty, name.count <= 60 else { return nil }
        return DriverRequirement(name: name, isGranted: verdict)
    }

    /// One word or glyph, if it decides anything.
    private static func decide(_ token: String) -> Bool? {
        let cleaned = token
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !cleaned.isEmpty else { return nil }
        if cleaned == "unknown" || cleaned == "notdetermined" { return nil }
        if granted.contains(cleaned) { return true }
        if refused.contains(cleaned) { return false }
        return nil
    }

    /// One sentence out of whatever a tool said, for the places that need to
    /// show a reason. Emoji and box-drawing are dropped, and only the first
    /// meaningful line survives — a failing CLI that prints thirty lines of
    /// stack trace has said everything useful in the first one.
    static func sentence(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let cleaned = String(line)
                .unicodeScalars
                .filter { $0.properties.isEmojiPresentation == false && $0.value > 0x20 || $0 == " " }
                .map(String.init)
                .joined()
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t-*•·✓✔✅✗✘❌"))
            if cleaned.count > 2 { return cleaned }
        }
        return nil
    }
}
