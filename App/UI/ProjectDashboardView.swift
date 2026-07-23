import SwiftUI

/// Project home: every session, git state, and the file tree in one place.
struct ProjectDashboardView: View {
    let project: Project
    @Binding var selection: MainSelection?
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var git = GitService.Snapshot()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                sessionsPanel
                HStack(alignment: .top, spacing: 14) {
                    gitPanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    filesPanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(16)
        }
        .task(id: project.id) { await refreshGit() }
    }

    private func refreshGit() async {
        let path = project.rootPath
        git = await Task.detached(priority: .utility) {
            GitService.snapshot(repoPath: path)
        }.value
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.claude)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(Theme.mono(16, .bold))
                    .foregroundStyle(Theme.text)
                Text(displayPath)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let branch = git.branch {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                    Text(branch)
                        .font(Theme.mono(11, .medium))
                    if !git.changedFiles.isEmpty {
                        Text("\(git.changedFiles.count) değişiklik")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.warn)
                    }
                }
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            }

            AgentLauncherStrip(project: project, selection: $selection)
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

    // MARK: - Sessions

    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeading(title: "Oturumlar", count: projectStore.sessions(for: project.id).count)

            let records = projectStore.sessions(for: project.id)
            if records.isEmpty {
                Text("Henüz oturum yok — sağ üstten bir agent başlat.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
                    .padding(14)
            } else {
                VStack(spacing: 1) {
                    ForEach(records) { record in
                        SessionCard(record: record) {
                            selection = .session(record.id)
                        }
                    }
                }
                .padding(6)
            }
        }
        .panel(radius: 12)
    }

    // MARK: - Git

    private var gitPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeading(title: "Git", count: git.changedFiles.count)

            if !git.isRepo {
                Text("Bu klasör bir git deposu değil.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
                    .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if git.changedFiles.isEmpty {
                        Label {
                            Text("Çalışma ağacı temiz")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.ok)
                        } icon: {
                            Circle().fill(Theme.ok).frame(width: 6, height: 6)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(git.changedFiles.prefix(12)) { file in
                                HStack(spacing: 8) {
                                    Text(file.status)
                                        .font(Theme.mono(10, .bold))
                                        .foregroundStyle(statusColor(file.status))
                                        .frame(width: 20, alignment: .leading)
                                    Text(file.path)
                                        .font(Theme.mono(11))
                                        .foregroundStyle(Theme.textDim)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            if git.changedFiles.count > 12 {
                                Text("+ \(git.changedFiles.count - 12) dosya daha")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                    }

                    if !git.recentCommits.isEmpty {
                        Divider().overlay(Theme.border)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(git.recentCommits) { commit in
                                HStack(spacing: 8) {
                                    Text(commit.hash)
                                        .font(Theme.mono(10))
                                        .foregroundStyle(Theme.codex)
                                    Text(commit.subject)
                                        .font(Theme.mono(11))
                                        .foregroundStyle(Theme.textDim)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(commit.relativeDate)
                                        .font(Theme.mono(9.5))
                                        .foregroundStyle(Theme.textFaint)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .panel(radius: 12)
    }

    private func statusColor(_ code: String) -> Color {
        switch code {
        case "M", "MM": Theme.warn
        case "A": Theme.ok
        case "D": Theme.danger
        case "??": Theme.textFaint
        default: Theme.textDim
        }
    }

    // MARK: - Files

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeading(title: "Dosyalar", count: nil)
            FileTreeView(rootURL: project.rootURL)
                .padding(6)
        }
        .panel(radius: 12)
    }
}

// MARK: - Pieces

private struct PanelHeading: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(Theme.textDim)
                .textCase(.uppercase)
                .kerning(0.6)
            if let count, count > 0 {
                Text("\(count)")
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.panelActive, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct SessionCard: View {
    let record: SessionRecord
    let onOpen: () -> Void
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var hovering = false

    private var status: AgentSessionStatus { sessionStore.status(of: record.id) }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                DotGlyph(color: record.provider.color, dotSize: 2.4)
                    .opacity(status == .terminated ? 0.4 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title)
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(status == .terminated ? Theme.textDim : Theme.text)
                        .lineLimit(1)
                    Text(record.provider.displayName)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                HStack(spacing: 6) {
                    StatusOrb(status: status, size: 11)
                    Text(status.label)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(status.color)
                }
                Text(RelativeClock.short(since: record.lastActivityAt))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - File tree

struct FileTreeView: View {
    let rootURL: URL

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                FileTreeLevel(directoryURL: rootURL, depth: 0)
            }
        }
        .frame(maxHeight: 340)
    }
}

private struct FileTreeLevel: View {
    let directoryURL: URL
    let depth: Int
    private let entries: [FileEntry]

    struct FileEntry: Identifiable {
        let url: URL
        let isDirectory: Bool
        var id: String { url.path }
    }

    init(directoryURL: URL, depth: Int) {
        self.directoryURL = directoryURL
        self.depth = depth
        // Synchronous listing at init: a capped local directory read is
        // fast, and async .task proved unreliable inside nested lazy stacks.
        entries = Self.list(directoryURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                FileTreeRow(entry: entry, depth: depth)
            }
            if entries.isEmpty {
                Text("boş")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.vertical, 6)
            }
        }
    }

    private static func list(_ directoryURL: URL) -> [FileEntry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .map { url in
                FileEntry(
                    url: url,
                    isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent
                    .localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
            .prefix(120)
            .map { $0 }
    }
}

private struct FileTreeRow: View {
    let entry: FileTreeLevel.FileEntry
    let depth: Int
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if entry.isDirectory {
                    withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                }
            } label: {
                HStack(spacing: 6) {
                    if entry.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    } else {
                        Spacer().frame(width: 10)
                    }
                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                        .font(.system(size: 10))
                        .foregroundStyle(entry.isDirectory ? Theme.warn.opacity(0.8) : Theme.textFaint)
                    Text(entry.url.lastPathComponent)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.leading, CGFloat(depth) * 14 + 8)
                .padding(.trailing, 8)
                .padding(.vertical, 3.5)
                .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                FileTreeLevel(directoryURL: entry.url, depth: depth + 1)
            }
        }
    }
}
