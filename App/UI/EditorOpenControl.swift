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
    private var directoryURL: URL { URL(fileURLWithPath: directory, isDirectory: true) }

    /// The editors this directory can be opened in — Xcode only when there is
    /// an Xcode project, workspace or package in it.
    private var candidates: [PreferredEditor] {
        PreferredEditor.available(forDirectory: directoryURL)
    }

    private var editor: PreferredEditor {
        let preferred = settings.preferredEditor
        let available = candidates
        guard !available.contains(preferred) else { return preferred }
        return available.first ?? preferred
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
            .buttonStyle(.pressable)
            .accessibilityIdentifier("editor.openButton")
            .help("Open the project directory in \(editor.displayName)")

            Menu {
                OpenDirectoryMenuItems(directory: directoryURL)
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
            .buttonStyle(.pressable)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("editor.menu")
        }
    }

    private func open(with editor: PreferredEditor) {
        editor.openProject(directoryURL)
    }
}

/// "Open in …" for every app that can take this directory, each with its own
/// icon, then Finder. Written once so the dashboard's editor menu, the session
/// `⋯` and the menu bar's Session menu offer the same list.
struct OpenDirectoryMenuItems: View {
    let directory: URL
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ForEach(PreferredEditor.available(forDirectory: directory)) { candidate in
            Button {
                settings.preferredEditor = candidate
                settings.save()
                candidate.openProject(directory)
            } label: {
                Self.label(String(localized: "Open in \(candidate.displayName)"), icon: candidate.appIcon)
            }
        }
        Divider()
        // Opens the folder itself, not its parent with the folder selected —
        // the project's contents are what was asked for.
        Button {
            NSWorkspace.shared.open(directory)
        } label: {
            Self.label(String(localized: "Open in Finder"), icon: Self.finderIcon)
        }
    }

    /// A menu item with the app's icon. `Label` is what an AppKit-backed menu
    /// turns into an item image; an `Image` beside a `Text` is dropped.
    static func label(_ title: String, icon: NSImage?) -> some View {
        Label {
            Text(title)
        } icon: {
            if let icon { Image(nsImage: icon) }
        }
    }

    static let finderIcon: NSImage? = {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.finder"
        ) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()
}
