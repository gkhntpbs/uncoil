import SwiftUI

struct SessionDetailView: View {
    let record: SessionRecord
    let project: Project
    @Binding var selection: MainSelection?
    var splitSessionID: Binding<UUID?>?
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var showChangesPanel = false
    @State private var restartToken = 0
    @State private var git = GitService.Snapshot()

    private var status: AgentSessionStatus {
        sessionStore.status(of: record.id)
    }

    private var account: AccountProfile? {
        settings.account(id: record.accountID)
    }

    private var workingDirectory: String {
        record.workingDirectory(in: project)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                // Selecting a session always (re)starts its agent: the registry
                // reuses a live terminal or launches fresh (resuming Claude when
                // a provider session id is known). No "restart" screen.
                TerminalHostView(record: record, project: project, account: account)
                    .id(restartToken)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            if showChangesPanel {
                ChangesPanel(
                    workingDirectory: workingDirectory,
                    git: $git,
                    onClose: { toggleChangesPanel(false) }
                )
                .frame(width: 320)
                .transition(.move(edge: .trailing))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.container")
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let splitBinding = splitSessionID,
                  let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String,
                      let droppedID = UUID(uuidString: string),
                      droppedID != record.id else { return }
                Task { @MainActor in
                    splitBinding.wrappedValue = droppedID
                }
            }
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
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

            ProviderMark(provider: record.provider, size: 17)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(record.provider.displayName)
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(Theme.text)
                    Text(record.displayTitle)
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

            controlCluster
        }
        .padding(14)
        .panel(radius: 12)
    }

    /// Session controls: open last change in editor · restart · changes panel.
    private var controlCluster: some View {
        HStack(spacing: 2) {
            // Editor: the selected app's real icon opens the last change;
            // the chevron menu picks among the user's installed editors.
            Button {
                openLastChange()
            } label: {
                Group {
                    if let icon = settings.preferredEditor.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 15, height: 15)
                    } else {
                        TablerIcon(name: "pencil", size: 13, color: Theme.textDim)
                    }
                }
                .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("session.openLastChangeButton")
            .help("Son değişen dosyayı \(settings.preferredEditor.displayName) ile aç")

            Menu {
                ForEach(PreferredEditor.installed) { editor in
                    Button {
                        settings.preferredEditor = editor
                        settings.save()
                        openLastChange()
                    } label: {
                        if let icon = editor.appIcon {
                            Image(nsImage: icon)
                        }
                        Text(editor.displayName)
                    }
                }
                Divider()
                Button("Klasörü Finder'da Aç") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: workingDirectory)]
                    )
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 16, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("session.editorMenu")

            Rectangle().fill(Theme.border).frame(width: 1, height: 16)

            ControlButton(
                iconName: "refresh",
                help: "Oturumu yeniden başlat" +
                    (record.providerSessionID != nil ? " (geçmişiyle devam eder)" : ""),
                identifier: "session.restartButton"
            ) {
                restart()
            }

            Rectangle().fill(Theme.border).frame(width: 1, height: 16)

            ControlButton(
                iconName: showChangesPanel ? "chevron-right" : "chevron-down",
                help: "Değişiklikler panelini aç/kapat",
                identifier: "session.changesButton"
            ) {
                toggleChangesPanel(!showChangesPanel)
            }
        }
        .padding(3)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workingDirectory.hasPrefix(home) {
            return "~" + workingDirectory.dropFirst(home.count)
        }
        return workingDirectory
    }

    // MARK: - Actions

    private func restart() {
        TerminalRegistry.shared.closeTerminal(for: record.id)
        projectStore.updateSession(record.id) { $0.lastActivityAt = .now }
        restartToken += 1
    }

    private func openLastChange() {
        let dir = workingDirectory
        let editor = settings.preferredEditor
        Task.detached(priority: .userInitiated) {
            guard let file = GitService.lastChangedFile(repoPath: dir) else { return }
            await MainActor.run {
                editor.open(URL(fileURLWithPath: file))
            }
        }
    }

    private func toggleChangesPanel(_ show: Bool) {
        withAnimation(uncoilAnimation(.easeOut(duration: 0.18))) {
            showChangesPanel = show
        }
    }
}

private struct ControlButton: View {
    let iconName: String
    let help: String
    let identifier: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TablerIcon(name: iconName, size: 13, color: hovering ? Theme.text : Theme.textDim)
                .frame(width: 26, height: 24)
                .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(identifier)
        .help(help)
    }
}

// MARK: - Changes panel

/// Right-side sliding panel: uncommitted changes + recent commits for the
/// session's working directory.
private struct ChangesPanel: View {
    let workingDirectory: String
    @Binding var git: GitService.Snapshot
    let onClose: () -> Void
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DEĞİŞİKLİKLER")
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.textDim)
                    .kerning(0.6)
                if let branch = git.branch {
                    Text(branch)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !git.isRepo {
                        Text("Bu klasör bir git deposu değil.")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textFaint)
                    } else {
                        if git.changedFiles.isEmpty {
                            Text("Çalışma ağacı temiz")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.ok)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(git.changedFiles) { file in
                                    ChangedFileRow(file: file, workingDirectory: workingDirectory)
                                }
                            }
                        }

                        if !git.recentCommits.isEmpty {
                            Divider().overlay(Theme.border)
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(git.recentCommits) { commit in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(commit.subject)
                                            .font(Theme.mono(11))
                                            .foregroundStyle(Theme.textDim)
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            Text(commit.hash)
                                                .font(Theme.mono(9.5))
                                                .foregroundStyle(Theme.codex)
                                            Text(commit.relativeDate)
                                                .font(Theme.mono(9.5))
                                                .foregroundStyle(Theme.textFaint)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .uncoilScrollers()
            }
        }
        .background(Theme.panel)
        .overlay(
            Rectangle().fill(Theme.border).frame(width: 1),
            alignment: .leading
        )
        .task(id: workingDirectory) { await refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.changesPanel")
    }

    private func refresh() async {
        let dir = workingDirectory
        git = await Task.detached(priority: .utility) {
            GitService.snapshot(repoPath: dir)
        }.value
    }
}

private struct ChangedFileRow: View {
    let file: GitService.ChangedFile
    let workingDirectory: String
    @EnvironmentObject private var settings: SettingsStore
    @State private var hovering = false

    var body: some View {
        Button {
            let url = URL(fileURLWithPath: workingDirectory).appendingPathComponent(file.path)
            settings.preferredEditor.open(url)
        } label: {
            HStack(spacing: 8) {
                Text(file.status)
                    .font(Theme.mono(10, .bold))
                    .foregroundStyle(file.status == "??" ? Theme.textFaint : Theme.warn)
                    .frame(width: 20, alignment: .leading)
                Text(file.path)
                    .font(Theme.mono(11))
                    .foregroundStyle(hovering ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(settings.preferredEditor.displayName) ile aç")
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


/// Right half of a drag-to-split: terminal + tiny header with close.
struct SplitSessionPane: View {
    let record: SessionRecord
    let project: Project
    let onClose: () -> Void
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ProviderMark(provider: record.provider, size: 12)
                Text(record.displayTitle)
                    .font(Theme.mono(11.5, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(project.name)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                StatusOrb(status: sessionStore.status(of: record.id), size: 11)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Bölmeyi kapat")
            }
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 8)

            TerminalHostView(
                record: record,
                project: project,
                account: settings.account(id: record.accountID)
            )
            .padding([.horizontal, .bottom], 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.splitPane")
    }
}
