import SwiftUI

/// What to do when an edit could not be applied because the file moved on inside
/// the very block being edited.
///
/// Uncoil does not choose for the user here. Recomputing an edit against changed
/// content is safe when the change was elsewhere; when it landed in the same
/// block, guessing would quietly overwrite someone's work.
struct TaskStaleEditSheet: View {
    enum Choice {
        /// Throw the pending edit away and show what is on disk.
        case reload
        /// Show both sides before deciding.
        case compare
        /// Leave the file alone and keep the screen as it is.
        case cancel
    }

    let taskText: String
    let detail: String
    let onChoose: (Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    TablerIcon(name: "alert-triangle", size: 13, color: Theme.warn)
                    Text("The edit could not be applied")
                        .font(Theme.mono(.large, .bold))
                        .foregroundStyle(Theme.text)
                }
                Text(taskText)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
            }
            Text(detail)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text("The file changed inside this task's block. It is your call what happens next.")
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                Spacer()
                Button("Cancel") { onChoose(.cancel) }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("staleEdit.cancel")
                Button("Compare") { onChoose(.compare) }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("staleEdit.compare")
                Button("Reload") { onChoose(.reload) }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("staleEdit.reload")
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Theme.bg)
        .accessibilityIdentifier("staleEdit.sheet")
    }
}

/// Builds the "mine vs theirs" text the compare option shows. Pure, so the
/// wording is testable without a window.
enum StaleEditComparison {
    static func text(
        taskText: String,
        attempted: String,
        onDisk: String?
    ) -> String {
        var sections = ["# Your edit — \(taskText)", attempted]
        if let onDisk, !onDisk.isEmpty {
            sections.append("# Dosyadaki hâli")
            sections.append(onDisk)
        } else {
            sections.append("# Dosyadaki hâli")
            sections.append("This task is not in the file; someone may have deleted or moved it.")
        }
        return sections.joined(separator: "\n\n")
    }
}
