import SwiftUI

/// A session's terminal in its own window — just the PTY, minimal chrome.
/// The terminal instance is shared with the main window via TerminalRegistry,
/// so both views drive the same process.
struct SessionPopoutWindow: View {
    let sessionID: UUID
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore

    private var record: SessionRecord? {
        projectStore.sessions.first { $0.id == sessionID }
    }

    private var project: Project? {
        record.flatMap { rec in projectStore.projects.first { $0.id == rec.projectID } }
    }

    var body: some View {
        Group {
            if let record, let project {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Spacer().frame(width: 70)  // traffic lights
                        ProviderMark(provider: record.provider, size: 13)
                        Text(record.displayTitle)
                            .font(Theme.mono(12, .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(project.name)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        StatusOrb(status: sessionStore.status(of: record.id), size: 12)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)

                    TerminalHostView(
                        record: record,
                        project: project,
                        account: settings.account(id: record.accountID)
                    )
                    .padding([.horizontal, .bottom], 8)
                }
            } else {
                Text("Session not found")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(edges: .top)
    }
}
