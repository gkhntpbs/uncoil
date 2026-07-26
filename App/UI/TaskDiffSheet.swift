import SwiftUI

/// What a task change actually did: the patch Uncoil wrote to `TODO.md`, and the
/// worktree's git diff underneath it.
struct TaskDiffSheet: View {
    let taskText: String
    let diff: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Change")
                    .font(Theme.mono(.large, .bold))
                    .foregroundStyle(Theme.text)
                Text(taskText)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider().overlay(Theme.border)
            ScrollView([.vertical, .horizontal]) {
                Text(diff)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .uncoilScrollers()
            .accessibilityIdentifier("taskDiff.body")
            Divider().overlay(Theme.border)
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(16)
        }
        .frame(width: 620, height: 480)
        .background(Theme.bg)
        .accessibilityIdentifier("taskDiff.sheet")
    }
}
