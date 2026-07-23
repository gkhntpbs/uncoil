import SwiftUI

struct SessionDetailView: View {
    let record: SessionRecord
    let project: Project
    @Binding var selection: MainSelection?
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore

    private var status: AgentSessionStatus {
        sessionStore.status(of: record.id)
    }

    private var account: AccountProfile? {
        settings.account(id: record.accountID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            // Selecting a session always (re)starts its agent: the registry
            // reuses a live terminal or launches fresh (resuming Claude when
            // a provider session id is known). No "restart" screen.
            TerminalHostView(record: record, project: project, account: account)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.container")
    }

    // MARK: - Header card

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                selection = .project(project.id)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 22, height: 22)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("session.backButton")
            .help("Proje panosuna dön")
            .padding(.top, 2)

            ProviderMark(provider: record.provider, size: 17)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(record.provider.displayName)
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(Theme.text)
                    Text(record.title)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let account {
                        Text(account.name)
                            .font(Theme.mono(11))
                            .foregroundStyle(record.provider.color.opacity(0.9))
                        Text("·")
                            .foregroundStyle(Theme.textFaint)
                    }
                    Text(displayPath)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            HStack(spacing: 7) {
                StatusOrb(status: status, size: 13)
                Text(sessionStore.detail(of: record.id) ?? status.label)
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(status.color.opacity(0.10), in: Capsule())
        }
        .padding(14)
        .panel(radius: 12)
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if project.rootPath.hasPrefix(home) {
            return "~" + project.rootPath.dropFirst(home.count)
        }
        return project.rootPath
    }

}

struct EmptyDetailView: View {
    @Binding var showFolderPicker: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ProviderMark(provider: .claude, size: 20)
                ProviderMark(provider: .codex, size: 20)
            }
            Text("Bir projenin üzerine gel, agent seç")
                .font(Theme.mono(13, .medium))
                .foregroundStyle(Theme.text)
            Text("Her agent aynı projeye yan yana açılır.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textFaint)
            Button("Proje Ekle") { showFolderPicker = true }
                .buttonStyle(AccentButtonStyle())
                .accessibilityIdentifier("empty.addProjectButton")
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
