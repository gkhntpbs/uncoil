import AppKit
import SwiftUI

/// The project screen's Issues area.
///
/// A peer of Tasks rather than a panel inside it. They look alike and are not:
/// a `TODO.md` task is a line in a file Uncoil may rewrite, an issue lives on
/// someone else's server and is shared with people who have never heard of
/// Uncoil. Mixing them into one list would invite edits that cannot be made.
struct ProjectIssuesView: View {
    let project: Project
    @Binding var selection: MainSelection?

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var store: IssueStore
    @State private var selectedLabel: String?
    @State private var expanded: Set<String> = []
    @State private var message: String?
    @State private var busyIssueID: String?
    @State private var commentDrafts: [String: String] = [:]

    init(project: Project, selection: Binding<MainSelection?>) {
        self.project = project
        _selection = selection
        _store = ObservedObject(wrappedValue: IssueStores.store(
            projectID: project.id, projectRoot: project.rootPath
        ))
    }

    private var visible: [GitHubIssue] {
        store.issues(labelled: selectedLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if let message {
                Text(message)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(radius: 8)
            }
            ForEach(store.problems, id: \.self) { problem in
                Text(problem)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.warn)
            }
            if !store.labels.isEmpty {
                labelFilter
            }
            if store.issues.isEmpty {
                if !store.hasLoadedOnce {
                    VStack(alignment: .leading, spacing: 14) {
                        SkeletonBlock(width: 180, height: 13)
                        SkeletonListRows(count: 4)
                    }
                    .padding(16)
                    .panel()
                } else {
                    emptyState
                }
            } else {
                ForEach(visible) { issue in
                    issueCard(issue)
                }
            }
        }
        .task(id: project.id) {
            if ProjectPageFreshness.needsRefresh(loadedAt: store.lastRefreshAt) {
                await store.refresh()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("issues.container")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("ISSUES")
                .font(Theme.mono(.micro, .semibold))
                .foregroundStyle(Theme.textFaint)
            if !store.issues.isEmpty {
                Text("\(visible.count)")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
            // Which repositories these came from. A project bound to more than
            // one would otherwise show two issues numbered #1.
            //
            // Summarised past two: five spelled out is a line longer than the
            // window, and every row already names its own repository.
            if store.repositories.count > 1 {
                Text(repositorySummary)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Yields before anything else in the row: it is a label,
                    // and the refresh button is a control.
                    .layoutPriority(-1)
                    .help(store.repositories.joined(separator: "\n"))
            }
            Spacer(minLength: 4)
            if store.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            ControlButton(
                iconName: "refresh",
                help: String(localized: "Fetch the issues again"),
                identifier: "issues.refresh"
            ) {
                Task { await store.refresh() }
            }
        }
    }

    private var repositorySummary: String {
        let names = store.repositories
        guard names.count > 2 else { return names.joined(separator: " · ") }
        return names.prefix(2).joined(separator: " · ")
            + String(localized: " +\(names.count - 2) more")
    }

    private var labelFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: String(localized: "All"), isOn: selectedLabel == nil, color: nil) {
                    selectedLabel = nil
                }
                ForEach(store.labels) { label in
                    chip(
                        title: label.name,
                        isOn: selectedLabel == label.name,
                        color: Color(hexString: label.color)
                    ) {
                        selectedLabel = selectedLabel == label.name ? nil : label.name
                    }
                }
            }
        }
    }

    private func chip(
        title: String, isOn: Bool, color: Color?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let color {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                Text(title)
                    .font(Theme.mono(.small, isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? Theme.bg : Theme.textDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isOn ? Theme.highlight : Theme.panel, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("issues.label.\(title)")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.problems.isEmpty ? "No open issues" : "Could not read the issues")
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.text)
            Text(store.problems.isEmpty
                 ? "Uncoil looks at the GitHub remote of this folder and of the repositories one level inside it. A private repository needs a token — sign in from Settings › Integrations."
                 : "See the messages above. A private repository needs a token.")
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func issueCard(_ issue: GitHubIssue) -> some View {
        let isExpanded = expanded.contains(issue.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                TablerIcon(name: "circle-dot", size: 12, color: Theme.ok)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        // The repository rides along with the number: two repos
                        // both have a #1, and the number alone would be a lie.
                        Text("\(issue.repository)#\(issue.number)")
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textFaint)
                        Text(issue.author)
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textFaint)
                        if issue.commentCount > 0 {
                            Text("\(issue.commentCount) comments")
                                .font(Theme.mono(.micro))
                                .foregroundStyle(Theme.textFaint)
                        }
                        if let updated = issue.updatedAt {
                            Text(RelativeClock.short(since: updated))
                                .font(Theme.mono(.micro))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    if !issue.labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(issue.labels) { label in
                                Text(label.name)
                                    .font(Theme.mono(.micro))
                                    .foregroundStyle(Theme.textDim)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Color(hexString: label.color).opacity(0.22), in: Capsule()
                                    )
                            }
                        }
                    }
                }
                Spacer(minLength: 6)
                if busyIssueID == issue.id {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                }
                ControlButton(
                    iconName: "robot",
                    help: String(localized: "Hand this issue to an agent"),
                    identifier: "issues.send.\(issue.number)",
                    tint: Theme.highlight
                ) {
                    sendToAgent(issue)
                }
                if let url = issue.htmlURL {
                    ControlButton(
                        iconName: "external-link",
                        help: String(localized: "Open on GitHub"),
                        identifier: "issues.open.\(issue.number)"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
                ControlButton(
                    iconName: isExpanded ? "chevron-up" : "chevron-down",
                    help: isExpanded
                        ? String(localized: "Hide the details")
                        : String(localized: "Show the details"),
                    identifier: "issues.expand.\(issue.number)"
                ) {
                    if isExpanded { expanded.remove(issue.id) } else { expanded.insert(issue.id) }
                }
            }
            if isExpanded {
                details(issue)
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("issues.issue.\(issue.number)")
    }

    private func details(_ issue: GitHubIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if issue.body.isEmpty {
                Text("No description.")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
            } else {
                // Selectable and plain: an issue body is text someone else
                // wrote, and rendering it as anything richer invites reading
                // it as part of the app's own interface.
                Text(issue.body)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !issue.assignees.isEmpty {
                Text("Assigned to \(issue.assignees.joined(separator: ", "))")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
            HStack(spacing: 6) {
                TextField(
                    String(localized: "Add a comment"),
                    text: Binding(
                        get: { commentDrafts[issue.id] ?? "" },
                        set: { commentDrafts[issue.id] = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(Theme.mono(.small))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .accessibilityIdentifier("issues.comment.\(issue.number)")

                Button(action: { comment(on: issue) }) { Text("Comment") }
                    .buttonStyle(GhostButtonStyle())
                    .disabled((commentDrafts[issue.id] ?? "").trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty)

                Button(action: { close(issue) }) { Text("Close") }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("issues.close.\(issue.number)")
            }
        }
        .padding(.leading, 20)
    }

    // MARK: - Actions

    private func sendToAgent(_ issue: GitHubIssue) {
        let record = projectStore.createSession(
            projectID: project.id,
            provider: settings.defaultProvider,
            accountID: nil,
            title: "#\(issue.number) \(issue.title)"
        )
        selection = .session(record.id)
        let prompt = GitHubIssueService.agentPrompt(for: issue)
        Task { @MainActor in
            await TerminalRegistry.shared.submitText(
                prompt, for: record.id, provider: record.provider
            )
        }
    }

    private func comment(on issue: GitHubIssue) {
        let text = (commentDrafts[issue.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busyIssueID = issue.id
        Task { @MainActor in
            switch await GitHubIssueService.comment(on: issue, body: text) {
            case .success:
                commentDrafts[issue.id] = ""
                message = String(localized: "Commented on #\(issue.number).")
                await store.refresh()
            case .failure(let error):
                message = error.localizedDescription
            }
            busyIssueID = nil
        }
    }

    private func close(_ issue: GitHubIssue) {
        busyIssueID = issue.id
        Task { @MainActor in
            switch await GitHubIssueService.setState("closed", on: issue) {
            case .success:
                var closed = issue
                closed.state = "closed"
                store.apply(closed)
                message = String(localized: "Closed #\(issue.number).")
            case .failure(let error):
                message = error.localizedDescription
            }
            busyIssueID = nil
        }
    }
}
