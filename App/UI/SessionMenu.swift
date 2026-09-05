import AppKit
import SwiftUI

/// What you can do to a session, written once.
///
/// The session header had grown a control per verb — restart, editor, run,
/// handoff, each its own square icon — and none of them had a menu item or a
/// shortcut, so the only way to reach any of them was to be looking at that
/// session's header with a mouse. Meanwhile the same verbs existed again in the
/// command palette under different names.
///
/// One list, rendered twice: as the header's `⋯` and as the menu bar's Session
/// menu. A verb added here appears in both, with the same words and the same
/// shortcut, which is the only way the two stay in step.
struct SessionMenuContent: View {
    let record: SessionRecord
    let project: Project
    let onRestart: () -> Void
    /// Offered only while the session's login is close to its limit; the header
    /// shows the same thing as a button when it is urgent.
    var onHandoff: (() -> Void)?

    @EnvironmentObject private var settings: SettingsStore

    private var directory: URL {
        URL(fileURLWithPath: record.workingDirectory(in: project), isDirectory: true)
    }

    /// The stored preference can be an app that cannot take a folder (TextEdit),
    /// so this falls back to the first installed one that can rather than doing
    /// nothing when chosen.
    private var editor: PreferredEditor {
        let preferred = settings.preferredEditor
        guard !preferred.opensDirectories else { return preferred }
        return PreferredEditor.directoryCapable.first ?? preferred
    }

    var body: some View {
        Button(String(localized: "Open in \(editor.displayName)")) {
            editor.open(directory)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])

        Button(String(localized: "Reveal in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }

        Button(String(localized: "Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(directory.path, forType: .string)
        }

        if let onHandoff {
            Divider()
            Button(String(localized: "Hand the Work to Another Agent…"), action: onHandoff)
        }

        Divider()

        // Said out loud rather than left to be discovered: a provider that can
        // resume comes back into the same conversation, and one that cannot
        // starts a new one — which is the difference between a restart being
        // free and being expensive.
        Button(
            record.providerSessionID != nil
                ? String(localized: "Restart, Continuing the Conversation")
                : String(localized: "Restart the Session"),
            action: onRestart
        )
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}

/// The header's `⋯`.
struct SessionMenuButton: View {
    let record: SessionRecord
    let project: Project
    let onRestart: () -> Void
    var onHandoff: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Menu {
            SessionMenuContent(
                record: record, project: project,
                onRestart: onRestart, onHandoff: onHandoff
            )
        } label: {
            TablerIcon(
                name: "dots",
                size: 13,
                color: hovering ? Theme.text : Theme.textDim
            )
            .frame(width: 26, height: 24)
            .background(
                hovering ? Theme.panelHover : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
        }
        .menuStyle(.button)
        .buttonStyle(.pressable)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(String(localized: "What you can do to this session"))
        .accessibilityIdentifier("session.actionsMenu")
    }
}

/// The menu bar's Session menu.
///
/// It acts on whatever the front window has selected, which `Router` already
/// knows — the notification policy reads the same value to stay quiet about the
/// session the user is looking at. When nothing is selected the menu is there
/// and disabled, rather than appearing and disappearing: a menu that comes and
/// goes cannot be learned.
struct SessionCommands: Commands {
    @ObservedObject private var router = Router.shared

    var body: some Commands {
        CommandMenu(String(localized: "Session")) {
            if let (record, project) = current {
                SessionMenuContent(
                    record: record,
                    project: project,
                    onRestart: {
                        guard let services = stores else { return }
                        SessionActions(projects: services.0, sessions: services.1)
                            .restart(record.id)
                    },
                    // The handoff sheet belongs to the session's own header, so
                    // the menu asks for it rather than raising one of its own.
                    onHandoff: { Router.shared.go(to: .handoff(sessionID: record.id)) }
                )
                .environmentObject(AppServices.shared.settings)
            } else {
                Button(String(localized: "No Session Selected")) {}
                    .disabled(true)
            }
        }
    }

    private var stores: (ProjectStore, SessionStore)? {
        guard let projects = AppServices.shared.projectStore,
              let sessions = AppServices.shared.sessionStore
        else { return nil }
        return (projects, sessions)
    }

    private var current: (SessionRecord, Project)? {
        guard case .session(let id) = router.currentSelection,
              let projects = AppServices.shared.projectStore,
              let record = projects.sessions.first(where: { $0.id == id }),
              let project = projects.projects.first(where: { $0.id == record.projectID })
        else { return nil }
        return (record, project)
    }
}
