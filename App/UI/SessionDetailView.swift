import SwiftUI

struct SessionDetailView: View {
    let record: SessionRecord
    let project: Project
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

            if TerminalRegistry.shared.hasTerminal(for: record.id) || status != .terminated {
                TerminalHostView(record: record, project: project, account: account)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                deadSessionView
            }
        }
    }

    // MARK: - Header card

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            DotGlyph(color: record.provider.color, dotSize: 3.4)
                .padding(.top, 4)

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

    // MARK: - Dead session

    private var deadSessionView: some View {
        VStack(spacing: 14) {
            DotGlyph(color: record.provider.color.opacity(0.5), dotSize: 4)
            Text("Bu oturum kapandı")
                .font(Theme.mono(13, .medium))
                .foregroundStyle(Theme.textDim)
            Button("Yeniden Başlat") {
                projectStore.updateSession(record.id) { $0.lastActivityAt = .now }
                sessionStore.setStatus(.running, for: record.id)
            }
            .buttonStyle(AccentButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyDetailView: View {
    @Binding var showFolderPicker: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                DotGlyph(color: Theme.claude, dotSize: 4)
                DotGlyph(color: Theme.codex, dotSize: 4, litPattern: [false, true, true, true, false, true])
            }
            Text("Bir projenin üzerine gel, agent seç")
                .font(Theme.mono(13, .medium))
                .foregroundStyle(Theme.text)
            Text("Her agent aynı projeye yan yana açılır.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textFaint)
            Button("Proje Ekle") { showFolderPicker = true }
                .buttonStyle(AccentButtonStyle())
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
