import SwiftUI

/// "Open this directory" — the editor's own icon, with a menu for the other
/// installed editors and for Finder.
///
/// One control rather than three: the project dashboard, a session and the
/// split pane all mean the same thing by it, and a button that opened a folder
/// in one place and a file in another was the confusing part.
struct EditorOpenControl: View {
    /// The directory to hand over — a project root, or a session's worktree.
    let directory: String
    @EnvironmentObject private var settings: SettingsStore

    /// The editor the button acts as. The stored preference can be an app that
    /// cannot take a folder (TextEdit), so the button falls back to the first
    /// installed one that can rather than doing nothing when pressed.
    private var editor: PreferredEditor {
        let preferred = settings.preferredEditor
        guard !preferred.opensDirectories else { return preferred }
        return PreferredEditor.directoryCapable.first ?? preferred
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                open(with: editor)
            } label: {
                Group {
                    if let icon = editor.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 15, height: 15)
                    } else {
                        TablerIcon(name: "pencil", size: 13, color: Theme.textDim)
                    }
                }
                .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("editor.openButton")
            .help("Open the project directory in \(editor.displayName)")

            Menu {
                ForEach(PreferredEditor.directoryCapable) { candidate in
                    Button {
                        settings.preferredEditor = candidate
                        settings.save()
                        open(with: candidate)
                    } label: {
                        if let icon = candidate.appIcon {
                            Image(nsImage: icon)
                        }
                        Text(candidate.displayName)
                    }
                }
                Divider()
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: directory, isDirectory: true)]
                    )
                }
            } label: {
                // A hint, not a control of its own: the editor icon beside it is
                // what the eye should land on, so this stays as small and as
                // quiet as it can be while still being hittable.
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 12, height: 22)
            }
            // `.borderlessButton` draws the label its own way: it ignored both
            // the font and the colour set above, which is why the chevron kept
            // coming back full-size and near-white. `.button` + `.plain` hands
            // the drawing back to the label.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("editor.menu")
        }
    }

    private func open(with editor: PreferredEditor) {
        editor.open(URL(fileURLWithPath: directory, isDirectory: true))
    }
}
