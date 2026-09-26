import SwiftUI

/// A unified diff, read line by line.
///
/// Pure, so what counts as an addition or a hunk header is testable without
/// drawing anything.
enum UnifiedDiff {
    struct Line: Equatable, Identifiable {
        enum Kind: Equatable {
            case added
            case removed
            case context
            /// `@@ … @@`: where the next lines are.
            case hunk
            /// `diff --git`, `index`, `---`, `+++`: which file.
            case header
        }

        let id: Int
        let kind: Kind
        /// The line without its `+`, `-` or space.
        let text: String
    }

    static func lines(_ diff: String) -> [Line] {
        var result: [Line] = []
        for (index, raw) in diff.components(separatedBy: "\n").enumerated() {
            let kind: Line.Kind
            var text = Substring(raw)
            if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("diff ")
                || raw.hasPrefix("index ") || raw.hasPrefix("new file") || raw.hasPrefix("deleted file") {
                kind = .header
            } else if raw.hasPrefix("@@") {
                kind = .hunk
            } else if raw.hasPrefix("+") {
                kind = .added
                text = text.dropFirst()
            } else if raw.hasPrefix("-") {
                kind = .removed
                text = text.dropFirst()
            } else {
                kind = .context
                if raw.hasPrefix(" ") { text = text.dropFirst() }
            }
            result.append(Line(id: index, kind: kind, text: String(text)))
        }
        // A trailing newline is the end of the last line, not an empty one.
        if result.last?.kind == .context, result.last?.text.isEmpty == true, diff.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }

    static func stats(_ diff: String) -> (added: Int, removed: Int) {
        lines(diff).reduce(into: (0, 0)) { counts, line in
            switch line.kind {
            case .added: counts.0 += 1
            case .removed: counts.1 += 1
            default: break
            }
        }
    }
}

/// Draws a unified diff: additions and removals tinted, hunks and file headers
/// quiet, everything in the fixed-width face so the code keeps its shape.
struct UnifiedDiffView: View {
    let diff: String
    /// Lines drawn before the rest is summarised; a generated file must not
    /// put ten thousand rows on screen.
    var lineLimit = 400

    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        let lines = UnifiedDiff.lines(diff)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.prefix(lineLimit)) { line in
                row(line)
            }
            if lines.count > lineLimit {
                Text("\(lines.count - lineLimit) more lines")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ line: UnifiedDiff.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sign(line.kind))
                .foregroundStyle(signColor(line.kind))
                .frame(width: 10, alignment: .center)
            // Wrapped, not scrolled sideways: a tinted line has to span the
            // box to read as a line, and the box is only as wide as the chat.
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(textColor(line.kind))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.mono(.small))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
    }

    private func sign(_ kind: UnifiedDiff.Line.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private func signColor(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added: Theme.ok
        case .removed: Theme.danger
        default: Theme.textFaint
        }
    }

    private func textColor(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .hunk, .header: Theme.textFaint
        case .context: Theme.textDim
        default: Theme.text
        }
    }

    private func background(_ kind: UnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .added: Theme.ok.opacity(0.10)
        case .removed: Theme.danger.opacity(0.10)
        case .hunk: Theme.info.opacity(0.06)
        default: .clear
        }
    }
}
