import AppKit
import SwiftUI

/// Run / Dev Preview area of the project dashboard: the configurations from
/// the repo-owned `.uncoil/run.json` with start/stop/restart, live status,
/// log tails, detection and an editor. The file is re-read on every appearance
/// and after every action, so edits made by agents (or by hand) show up
/// without any hidden app-side copy.
struct ProjectRunView: View {
    let project: Project
    @ObservedObject private var registry = RunRegistry.shared
    @State private var configurations: [RunConfiguration] = []
    @State private var problems: [String] = []
    @State private var detecting = false
    @State private var editing: RunConfiguration?
    @State private var expandedLogs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            if !problems.isEmpty {
                problemsBanner
            }
            if configurations.isEmpty {
                emptyState
            } else {
                ForEach(configurations) { config in
                    RunConfigurationRow(
                        project: project,
                        config: config,
                        state: registry.state(project: project, configID: config.id),
                        showLog: expandedLogs.contains(config.id),
                        onToggleLog: { toggleLog(config.id) },
                        onEdit: { editing = config },
                        onReload: reload
                    )
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing) { config in
            RunConfigurationEditor(project: project, original: config, onSaved: reload)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run.container")
    }

    private func reload() {
        let contents = RunConfigFile.load(projectRoot: project.rootURL)
        configurations = contents.configurations
        problems = contents.problems
    }

    private func toggleLog(_ id: String) {
        if !expandedLogs.insert(id).inserted { expandedLogs.remove(id) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Run configurations")
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.text)
            Text(RunConfigFile.relativePath)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .textSelection(.enabled)
            Spacer()
            Button {
                detect()
            } label: {
                HStack(spacing: 5) {
                    TablerIcon(name: "radar-2", size: 12, color: Theme.textDim)
                    Text(detecting ? "Scanning…" : "Detect")
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(detecting)
            .accessibilityIdentifier("run.detect")
            Button {
                editing = RunConfiguration(
                    id: "", name: "", command: "", source: .user
                )
            } label: {
                HStack(spacing: 5) {
                    TablerIcon(name: "plus", size: 12, color: Theme.textDim)
                    Text("New").font(Theme.mono(.body)).foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("run.add")
        }
    }

    private func detect() {
        detecting = true
        let root = project.rootURL
        Task {
            let existing = RunConfigFile.load(projectRoot: root).configurations
            let suggestions = await Task.detached {
                RunDetection.detect(fileSystem: DiskRunDetectionFileSystem(root: root))
            }.value
            let merged = RunDetection.merge(
                existing: existing, suggestions: suggestions, replacingDetected: false
            )
            try? RunConfigFile.save(merged, projectRoot: root)
            detecting = false
            reload()
        }
    }

    private var problemsBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { problem in
                Text(problem)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.warn)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warnSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No run configuration yet.")
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textDim)
            Text("“Detect” derives suggestions from the project's files; or write \(RunConfigFile.relativePath) by hand (or have an agent write it).")
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Session header button that runs the project's default configuration: play
/// when idle, stop while starting/running. Hidden when the project has no
/// default (and no single obvious) configuration.
struct RunDefaultControl: View {
    let project: Project
    @ObservedObject private var registry = RunRegistry.shared
    @State private var busy = false

    var body: some View {
        // Read the file on render rather than caching in @State: an empty
        // conditional view never fires onAppear, which is exactly how a cached
        // copy stays nil forever. The file is tiny and header renders are rare
        // (status ticks), so the read is negligible — and edits made in the Run
        // tab or by an agent show up the next time the header draws.
        let configurations = RunConfigFile.load(projectRoot: project.rootURL).configurations
        if let config = RunConfigFile.defaultConfiguration(configurations) {
            let status = registry.state(project: project, configID: config.id).status
            let active = status == .running || status == .starting
            if status == .starting {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 18, height: 24)
                    .help("\(config.name) starting…")
            }
            ControlButton(
                iconName: active ? "player-stop" : "player-play",
                help: active ? "\(config.name) — durdur" : "\(config.name) — run",
                identifier: "session.runButton",
                tint: status == .failed ? Theme.warn : (active ? Theme.danger : Theme.ok)
            ) {
                guard !busy else { return }
                busy = true
                let project = project
                let id = config.id
                Task { @MainActor in
                    if active {
                        await RunRegistry.shared.stop(project: project, configID: id)
                    } else {
                        _ = await RunRegistry.shared.start(project: project, configID: id)
                    }
                    busy = false
                }
            }

            Rectangle().fill(Theme.border).frame(width: 1, height: 16)
        }
    }
}

// MARK: - Row

private struct RunConfigurationRow: View {
    let project: Project
    let config: RunConfiguration
    let state: RunProcessState
    let showLog: Bool
    let onToggleLog: () -> Void
    let onEdit: () -> Void
    let onReload: () -> Void
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var busy = false
    @State private var inputText = ""
    @State private var showHistory = false
    @State private var repairNote: String?
    @State private var confirmingDelete = false

    private var statusColor: Color {
        switch state.status {
        case .running: Theme.ok
        case .starting: Theme.info
        case .failed: Theme.danger
        case .exited(let code): code == 0 ? Theme.textFaint : Theme.warn
        case .idle: Theme.textFaint
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(config.name)
                            .font(Theme.mono(.body, .semibold))
                            .foregroundStyle(Theme.text)
                        Text(config.id)
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textFaint)
                        sourceBadge
                        if config.isDefault {
                            Text("default")
                                .font(Theme.mono(.micro))
                                .foregroundStyle(Theme.info)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.infoSurface, in: Capsule())
                        }
                    }
                    Text("\(config.command)  ·  \(config.cwd)")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                statusText
                controls
            }
            // A living 3-line pulse of the process without opening the full
            // log — enough to see a compile tick or a crash line at a glance.
            if !showLog, !state.logTail.isEmpty,
               state.status != .idle {
                Text(lastLines(state.logTail, 3))
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
            if let issue = state.issue {
                issueBanner(issue)
            }
            if state.status == .running, let preview = config.previewURL,
               let url = URL(string: preview) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        TablerIcon(name: "external-link", size: 11, color: Theme.info)
                        Text(preview).font(Theme.mono(.small)).foregroundStyle(Theme.info)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("run.preview.\(config.id)")
            }
            if showLog {
                logView
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run.row.\(config.id)")
    }

    private var sourceBadge: some View {
        Text(config.source.rawValue)
            .font(Theme.mono(.micro))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.statusSurface, in: Capsule())
    }

    private var statusText: some View {
        HStack(spacing: 5) {
            if state.status == .starting {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
            Text(statusLabel)
                .font(Theme.mono(.small))
                .foregroundStyle(statusColor)
        }
    }

    private var statusLabel: String {
        switch state.status {
        case .idle: "ready"
        case .starting: "starting…"
        case .running: state.pid.map { "running · pid \($0)" } ?? "running"
        case .exited(let code): "bitti (\(code))"
        case .failed: "failed"
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            if state.status == .running || state.status == .starting {
                iconButton("player-stop", tint: Theme.danger, id: "run.stop.\(config.id)") {
                    await RunRegistry.shared.stop(project: project, configID: config.id)
                }
                iconButton("Refresh", id: "run.restart.\(config.id)") {
                    _ = await RunRegistry.shared.restart(project: project, configID: config.id)
                }
            } else {
                iconButton("player-play", tint: Theme.ok, id: "run.start.\(config.id)") {
                    _ = await RunRegistry.shared.start(project: project, configID: config.id)
                }
            }
            plainIconButton("History", id: "run.history.\(config.id)") {
                showHistory = true
            }
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                RunHistoryList(project: project, configID: config.id)
            }
            plainIconButton(
                "Star", tint: config.isDefault ? Theme.warn : Theme.textDim,
                id: "run.default.\(config.id)"
            ) {
                try? RunConfigFile.setDefault(config.id, projectRoot: project.rootURL)
                onReload()
            }
            plainIconButton("file-text", id: "run.log.\(config.id)", action: onToggleLog)
            plainIconButton("Pencil", id: "run.edit.\(config.id)", action: onEdit)
            plainIconButton("Trash", id: "run.delete.\(config.id)") {
                confirmingDelete = true
            }
            // A live process would orphan silently if its row vanished —
            // stop first, same rule as the MCP `remove` action.
            .disabled(state.status == .running || state.status == .starting)
            .confirmationDialog(
                "Delete the '\(config.name)' configuration?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let remaining = RunConfigFile.load(projectRoot: project.rootURL)
                        .configurations.filter { $0.id != config.id }
                    try? RunConfigFile.save(remaining, projectRoot: project.rootURL)
                    onReload()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removed from .uncoil/run.json; run history and logs stop.")
            }
        }
        .disabled(busy)
    }

    private func iconButton(
        _ icon: String, tint: Color? = nil, id: String, action: @escaping () async -> Void
    ) -> some View {
        Button {
            busy = true
            Task {
                await action()
                busy = false
                onReload()
            }
        } label: {
            TablerIcon(name: icon, size: 13, color: tint ?? Theme.textDim)
                .padding(5)
                .background(Theme.panelHover, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func plainIconButton(
        _ icon: String, tint: Color? = nil, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TablerIcon(name: icon, size: 13, color: tint ?? Theme.textDim)
                .padding(5)
                .background(Theme.panelHover, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func issueBanner(_ issue: RunIssue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.code)
                        .font(Theme.mono(.small, .semibold))
                        .foregroundStyle(Theme.danger)
                    Text(issue.hint)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    let handed = RunRepair.dispatch(
                        project: project, config: config, issue: issue,
                        logTail: state.logTail, projectStore: projectStore,
                        language: settings.language.resolvedAgent()
                    )
                    repairNote = handed
                        ? "Sent to the agent"
                        : "No live agent — the prompt was copied to the clipboard"
                } label: {
                    HStack(spacing: 5) {
                        TablerIcon(name: "wand", size: 11, color: Theme.textOnHighlight)
                        Text("Fix with agent")
                            .font(Theme.mono(.small, .semibold))
                            .foregroundStyle(Theme.textOnHighlight)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.highlight, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("run.repair.\(config.id)")
            }
            if let repairNote {
                Text(repairNote)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.dangerSurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func lastLines(_ text: String, _ count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(count).joined(separator: "\n")
    }

    private var logView: some View {
        VStack(spacing: 6) {
            ScrollView {
                Text(state.logTail.isEmpty ? "(no output yet)" : state.logTail)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .uncoilScrollers()
                    .padding(8)
            }
            .frame(height: 220)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
            if state.status == .running || state.status == .starting {
                HStack(spacing: 6) {
                    TextField("Send input to the process (r for Flutter, for example)", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(.small))
                        .onSubmit(sendInput)
                        .accessibilityIdentifier("run.input.\(config.id)")
                    Button("Send", action: sendInput)
                        .font(Theme.mono(.small))
                }
            }
        }
    }

    private func sendInput() {
        guard !inputText.isEmpty else { return }
        RunRegistry.shared.sendInput(project: project, configID: config.id, text: inputText)
        inputText = ""
    }
}

// MARK: - History

private struct RunHistoryList: View {
    let project: Project
    let configID: String

    var body: some View {
        let entries = RunRegistry.shared.history(project: project, configID: configID)
        VStack(alignment: .leading, spacing: 6) {
            Text("Previous runs")
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.text)
            if entries.isEmpty {
                Text("No records yet.")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
            }
            ForEach(entries) { entry in
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.logFile))
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(entry.exitCode == nil
                                ? Theme.info
                                : (entry.exitCode == 0 ? Theme.ok : Theme.danger))
                            .frame(width: 6, height: 6)
                        Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textDim)
                        Spacer()
                        Text(entry.exitCode.map { "exit \($0)" }
                            ?? (entry.endedAt == nil ? "in progress" : "stopped"))
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the log file")
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

// MARK: - Editor

private struct RunConfigurationEditor: View {
    let project: Project
    let original: RunConfiguration
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var id = ""
    @State private var name = ""
    @State private var command = ""
    @State private var cwd = "."
    @State private var envText = ""
    @State private var portsText = ""
    @State private var previewURL = ""
    @State private var readyPattern = ""
    @State private var dependsOnText = ""
    @State private var error: String?

    private var isNew: Bool { original.id.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New run configuration" : "Edit the configuration")
                .font(Theme.mono(.large, .semibold))
                .foregroundStyle(Theme.text)

            field("id (slug)", text: $id, disabled: !isNew)
            field("Name", text: $name)
            field("Command", text: $command)
            field("Working directory (relative to the root)", text: $cwd)
            field("Env (KEY=value, one per line)", text: $envText, axis: .vertical)
            field("Ports (comma-separated)", text: $portsText)
            field("Preview URL", text: $previewURL)
            field("Ready pattern (regex)", text: $readyPattern)
            field("Dependencies (ids, comma-separated)", text: $dependsOnText)

            if let error {
                Text(error).font(Theme.mono(.small)).foregroundStyle(Theme.danger)
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { remove() }
                        .accessibilityIdentifier("run.editor.delete")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("run.editor.save")
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear(perform: populate)
    }

    private func field(
        _ label: String, text: Binding<String>, disabled: Bool = false,
        axis: Axis = .horizontal
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.mono(.small)).foregroundStyle(Theme.textFaint)
            TextField("", text: text, axis: axis)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(.body))
                .disabled(disabled)
        }
    }

    private func populate() {
        id = original.id
        name = original.name
        command = original.command
        cwd = original.cwd
        envText = original.env.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        portsText = original.ports.map(String.init).joined(separator: ", ")
        previewURL = original.previewURL ?? ""
        readyPattern = original.readyPattern ?? ""
        dependsOnText = original.dependsOn.joined(separator: ", ")
    }

    private func save() {
        let slug = id.trimmingCharacters(in: .whitespaces)
        guard !slug.isEmpty, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = String(localized: "id and command are required.")
            return
        }
        var env: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            env[String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: equals)...])
        }
        let config = RunConfiguration(
            id: slug,
            name: name.isEmpty ? slug : name,
            command: command,
            cwd: cwd.isEmpty ? "." : cwd,
            env: env,
            ports: portsText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            previewURL: previewURL.isEmpty ? nil : previewURL,
            readyPattern: readyPattern.isEmpty ? nil : readyPattern,
            dependsOn: dependsOnText.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            source: .user,
            notes: original.notes,
            extra: original.extra
        )
        var all = RunConfigFile.load(projectRoot: project.rootURL).configurations
        if let index = all.firstIndex(where: { $0.id == slug }) {
            all[index] = config
        } else {
            all.append(config)
        }
        do {
            try RunConfigFile.save(all, projectRoot: project.rootURL)
            onSaved()
            dismiss()
        } catch {
            self.error = String(localized: "Could not be saved: \(error.localizedDescription)")
        }
    }

    private func remove() {
        let remaining = RunConfigFile.load(projectRoot: project.rootURL)
            .configurations.filter { $0.id != original.id }
        try? RunConfigFile.save(remaining, projectRoot: project.rootURL)
        onSaved()
        dismiss()
    }
}
