import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The project screen's Tasks area.
///
/// `TODO.md` stays the source of truth: every change here is a byte-range patch
/// through `TodoEditor`, and external edits arrive through the watcher rather
/// than being overwritten.
struct ProjectTasksView: View {
    let project: Project
    @Binding var selection: MainSelection?

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var sources: TodoSourceStore
    @StateObject private var metadata: ProjectTaskMetadataStore
    @State private var watcher: TodoSourceWatcher?
    @State private var message: String?
    @State private var conflictTaskIDs: Set<String> = []
    @State private var editingTaskID: String?
    @State private var editingText = ""
    /// Task awaiting a dispatch decision, with the document it came from.
    @State private var dispatchTarget: (task: ProjectTask, document: TaskDocument)?

    init(project: Project, selection: Binding<MainSelection?>) {
        self.project = project
        _selection = selection
        _sources = StateObject(wrappedValue: TodoSourceStore(
            projectID: project.id, projectRoot: project.rootPath
        ))
        _metadata = StateObject(wrappedValue: ProjectTaskMetadataStore(projectID: project.id))
    }

    private var preferences: ProjectTaskViewPreferences { metadata.preferences }

    /// Tasks for the selected source, or every source when aggregating.
    private var visibleTasks: [ProjectTask] {
        guard let path = preferences.selectedSourcePath else { return sources.allTasks }
        return sources.document(for: path)?.tasks ?? []
    }

    private var selectedDocuments: [TaskDocument] {
        if let path = preferences.selectedSourcePath {
            return sources.document(for: path).map { [$0] } ?? []
        }
        return sources.sources.compactMap { sources.document(for: $0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if let message {
                banner(message)
            }
            if sources.sources.isEmpty {
                emptyState
            } else {
                switch preferences.mode {
                case .document: documentView
                case .list: listView
                case .kanban: kanbanView
                case .sessions: sessionsView
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.container")
        .task(id: project.id) {
            await Task.yield()
            refresh()
            let watcher = TodoSourceWatcher { refresh() }
            watcher.start(paths: sources.sources.map(\.path) + [project.rootPath])
            self.watcher = watcher
        }
        .onDisappear { watcher?.stop() }
        .sheet(
            isPresented: Binding(
                get: { dispatchTarget != nil },
                set: { if !$0 { dispatchTarget = nil } }
            )
        ) {
            if let target = dispatchTarget {
                TaskDispatchSheet(
                    task: target.task,
                    document: target.document,
                    project: project,
                    onSend: { request in
                        dispatchTarget = nil
                        dispatch(request, task: target.task, document: target.document)
                    },
                    onCancel: { dispatchTarget = nil }
                )
                .environmentObject(projectStore)
                .environmentObject(sessionStore)
                .environmentObject(settings)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { preferences.mode },
                    set: { metadata.preferences.mode = $0; metadata.savePreferences() }
                )) {
                    ForEach(ProjectTaskViewPreferences.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("tasks.modePicker")

                Menu {
                    Button("Tüm kaynaklar (aggregate)") {
                        metadata.preferences.selectedSourcePath = nil
                        metadata.savePreferences()
                    }
                    Divider()
                    ForEach(sources.sources) { source in
                        Button(sourceLabel(source)) {
                            metadata.preferences.selectedSourcePath = source.path
                            metadata.savePreferences()
                        }
                    }
                } label: {
                    Text(
                        preferences.selectedSourcePath
                            .flatMap { path in sources.sources.first { $0.path == path } }
                            .map(\.displayPath) ?? "Tüm kaynaklar"
                    )
                    .font(Theme.mono(11, .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("tasks.sourcePicker")

                Spacer()

                Text("\(visibleTasks.filter { !$0.isDone }.count) açık / \(visibleTasks.count)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)

                Button {
                    refresh()
                } label: {
                    TablerIcon(name: "refresh", size: 12, color: Theme.textDim)
                }
                .buttonStyle(.plain)
                .help("Kaynakları yeniden tara")
                .accessibilityIdentifier("tasks.refresh")
            }

            sourceStatusStrip
        }
    }

    private func sourceLabel(_ source: ProjectTaskSource) -> String {
        let status = sources.status(for: source.path)
        return status.isMissing
            ? "\(source.displayPath) — \(status.label)"
            : "\(source.displayPath) (\(source.openTaskCount)/\(source.taskCount))"
    }

    /// Git state, last change and any parser or conflict warnings for the
    /// selected sources.
    private var sourceStatusStrip: some View {
        let shown = preferences.selectedSourcePath
            .flatMap { path in sources.sources.filter { $0.path == path } }
            ?? sources.sources
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { source in
                HStack(spacing: 8) {
                    TablerIcon(
                        name: sources.status(for: source.path).isMissing ? "file-off" : "file-text",
                        size: 11,
                        color: sources.status(for: source.path).isMissing ? Theme.danger : Theme.textDim
                    )
                    Text(source.displayPath)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.text)
                    if sources.status(for: source.path).isMissing {
                        Text(sources.status(for: source.path).label)
                            .font(Theme.mono(9.5, .semibold))
                            .foregroundStyle(Theme.danger)
                    }
                    if let change = sources.lastChanges[source.path] {
                        Text(changeLabel(change))
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textFaint)
                    }
                    Text("değişiklik \(RelativeClock.short(since: source.lastReadAt))")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textFaint)
                    if conflictTaskIDs.contains(where: { id in
                        sources.document(for: source.path)?.task(id: id) != nil
                    }) {
                        Text("conflict — dosya salt okunur")
                            .font(Theme.mono(9.5, .semibold))
                            .foregroundStyle(Theme.warn)
                    }
                    Spacer()
                }
            }
        }
    }

    private func changeLabel(_ change: TodoSourceChange) -> String {
        switch change {
        case .added: "eklendi"
        case .unchanged: "değişmedi"
        case .checkboxesChanged(let ids): "\(ids.count) checkbox"
        case .structureChanged: "yapı değişti"
        case .missing: "kayıp"
        case .restored: "geri geldi"
        case .moved(let from): "taşındı: \(URL(fileURLWithPath: from).lastPathComponent)"
        }
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            TablerIcon(name: "info-circle", size: 12, color: Theme.codex)
            Text(text)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button {
                message = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("tasks.message")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            TablerIcon(name: "list-check", size: 22, color: Theme.textFaint)
            Text("Bu projede TODO.md bulunamadı")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.textFaint)
            Text("Kök veya alt klasörlere TODO.md ekleyince burada görünür.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .panel()
        .accessibilityIdentifier("tasks.empty")
    }

    // MARK: - Document view

    private var documentView: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(selectedDocuments, id: \.path) { document in
                VStack(alignment: .leading, spacing: 6) {
                    if selectedDocuments.count > 1 {
                        Text(
                            sources.sources.first { $0.path == document.path }?.displayPath
                                ?? document.path
                        )
                        .font(Theme.mono(11, .semibold))
                        .foregroundStyle(Theme.textDim)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(documentRows(document), id: \.id) { row in
                            switch row.kind {
                            case .heading(let level, let text):
                                Text(text)
                                    .font(Theme.mono(level <= 1 ? 13 : 11.5, .semibold))
                                    .foregroundStyle(Theme.text)
                                    .padding(.leading, CGFloat(max(0, level - 1)) * 10)
                                    .padding(.top, 10)
                                    .padding(.bottom, 3)
                                    .padding(.horizontal, 12)
                            case .task(let task):
                                taskRow(task, in: document)
                            }
                        }
                    }
                    .panel()
                }
            }
        }
    }

    private struct DocumentRow: Identifiable {
        enum Kind {
            case heading(level: Int, text: String)
            case task(ProjectTask)
        }

        let id: String
        let kind: Kind
    }

    /// Headings and tasks in the file's own order.
    private func documentRows(_ document: TaskDocument) -> [DocumentRow] {
        var rows: [(startByte: Int, row: DocumentRow)] = []
        for heading in document.headings {
            rows.append((
                heading.range.startByte,
                DocumentRow(
                    id: "h-\(document.path)-\(heading.range.startByte)",
                    kind: .heading(level: heading.level, text: heading.text)
                )
            ))
        }
        for task in document.tasks {
            rows.append((
                task.blockRange.startByte,
                DocumentRow(id: task.id, kind: .task(task))
            ))
        }
        return rows.sorted { $0.startByte < $1.startByte }.map(\.row)
    }

    private func taskRow(_ task: ProjectTask, in document: TaskDocument) -> some View {
        let isExpanded = preferences.expandedTaskIDs.contains(task.id)
        let hasBody = task.rawBlock.contains("\n")
        let state = metadata.executionState(for: task.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    toggle(task, in: document)
                } label: {
                    Image(systemName: task.isDone ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(task.isDone ? Theme.ok : Theme.textFaint)
                }
                .buttonStyle(.plain)
                .disabled(conflictTaskIDs.contains(task.id))
                .accessibilityIdentifier("tasks.toggle.\(task.id)")

                if editingTaskID == task.id {
                    TextField("", text: $editingText, onCommit: { commitRename(task, in: document) })
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.text)
                        .accessibilityIdentifier("tasks.rename.\(task.id)")
                } else {
                    Text(task.text)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(task.isDone ? Theme.textDim : Theme.text)
                        .strikethrough(task.isDone, color: Theme.textFaint)
                        .onTapGesture(count: 2) {
                            editingTaskID = task.id
                            editingText = task.text
                        }
                }

                if state != .unassigned {
                    Text(state.label)
                        .font(Theme.mono(9, .semibold))
                        .foregroundStyle(state.needsAttention ? Theme.warn : Theme.codex)
                }

                Spacer(minLength: 4)

                if hasBody {
                    Button {
                        var expanded = preferences.expandedTaskIDs
                        if isExpanded { expanded.remove(task.id) } else { expanded.insert(task.id) }
                        metadata.preferences.expandedTaskIDs = expanded
                        metadata.savePreferences()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tasks.expand.\(task.id)")
                }

                Button {
                    revealSource(task)
                } label: {
                    TablerIcon(name: "external-link", size: 11, color: Theme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Kaynak satırı aç: \(task.lineRange.startLine)")
                .accessibilityIdentifier("tasks.reveal.\(task.id)")
            }
            .padding(.leading, CGFloat(task.depth) * 16)

            if isExpanded, hasBody {
                Text(task.rawBlock
                    .components(separatedBy: "\n")
                    .dropFirst()
                    .joined(separator: "\n"))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .padding(.leading, CGFloat(task.depth) * 16 + 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: - List view

    private var listView: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterBar
            let filtered = preferences.filter.apply(
                to: visibleTasks, assignments: metadata.assignmentsByTask
            )
            if filtered.isEmpty {
                EmptyTaskList(isFiltered: preferences.filter.isActive)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, task in
                        listRow(task)
                        if index != filtered.count - 1 {
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                .panel()
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TablerIcon(name: "search", size: 12, color: Theme.textFaint)
                TextField("Görev ara…", text: Binding(
                    get: { preferences.filter.query },
                    set: { metadata.preferences.filter.query = $0 }
                ))
                .textFieldStyle(.plain)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text)
                .onSubmit { metadata.savePreferences() }
                .accessibilityIdentifier("tasks.search")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .panel(radius: 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(TaskFilter.Status.allCases) { status in
                        let isOn = preferences.filter.status == status
                        Button {
                            metadata.preferences.filter.status = status
                            metadata.savePreferences()
                        } label: {
                            Text(status.title)
                                .font(Theme.mono(10, isOn ? .semibold : .regular))
                                .foregroundStyle(isOn ? Theme.bg : Theme.textDim)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    isOn ? Theme.codex : Theme.panel,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tasks.filter.\(status.rawValue)")
                    }
                }
            }
        }
    }

    private func listRow(_ task: ProjectTask) -> some View {
        let state = metadata.executionState(for: task.id)
        let assignments = metadata.assignments(for: task.id)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: task.isDone ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(task.isDone ? Theme.ok : Theme.textFaint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.text)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(task.headingPath.joined(separator: " › "))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textFaint)
                    Text(URL(fileURLWithPath: task.sourcePath).lastPathComponent)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textFaint)
                    if state != .unassigned {
                        Text(state.label)
                            .font(Theme.mono(9, .semibold))
                            .foregroundStyle(state.needsAttention ? Theme.warn : Theme.codex)
                    }
                    if assignments.contains(where: \.needsRelinking) {
                        Text("Needs relinking")
                            .font(Theme.mono(9, .semibold))
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            Spacer()
            ForEach(assignments) { assignment in
                Button {
                    selection = .session(assignment.sessionID)
                } label: {
                    Text(assignment.role.label)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.codex)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contextMenu { cardActions(task, in: documentFor(task)) }
        .accessibilityIdentifier("tasks.row.\(task.id)")
    }

    /// The document a task belongs to, needed by actions that patch the file.
    private func documentFor(_ task: ProjectTask) -> TaskDocument {
        sources.document(for: task.sourcePath)
            ?? TodoParser.parse("", path: task.sourcePath)
    }

    // MARK: - Kanban view

    private var kanbanView: some View {
        let document = selectedDocuments.first
        return VStack(alignment: .leading, spacing: 8) {
            if selectedDocuments.count != 1 {
                Text("Kanban tek bir kaynak üzerinde çalışır; yukarıdan bir TODO.md seç.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textFaint)
            }
            if let document {
                let columns = TaskBoardMapping.columns(
                    for: document,
                    overrides: preferences.headingOverrides,
                    columnOrder: preferences.columnOrder
                )
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(columns) { column in
                            kanbanColumn(column, in: document)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .uncoilScrollers()
            }
        }
    }

    private func kanbanColumn(
        _ column: TaskBoardMapping.Column,
        in document: TaskDocument
    ) -> some View {
        let tasks = TaskBoardMapping.tasks(in: column, of: document)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(column.title)
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(tasks.count)")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                if column.isCustom {
                    Menu {
                        ForEach(TaskBoardMapping.Lane.allCases) { lane in
                            Button(lane.title) {
                                metadata.preferences.headingOverrides[column.heading] = lane
                                metadata.savePreferences()
                            }
                        }
                    } label: {
                        TablerIcon(name: "settings", size: 10, color: Theme.textFaint)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Bu başlığı bir board durumuna eşle")
                }
            }
            ForEach(tasks) { task in
                kanbanCard(task, in: document)
            }
            if tasks.isEmpty {
                Text("boş")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 240, alignment: .topLeading)
        .padding(10)
        .panel()
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers, to: column, in: document)
        }
        .accessibilityIdentifier("tasks.column.\(column.heading)")
    }

    private func kanbanCard(_ task: ProjectTask, in document: TaskDocument) -> some View {
        let state = metadata.executionState(for: task.id)
        let assignments = metadata.assignments(for: task.id)
        let children = task.childIDs.compactMap { document.task(id: $0) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: task.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundStyle(task.isDone ? Theme.ok : Theme.textFaint)
                Text(task.text)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
            }
            if !children.isEmpty {
                ForEach(children) { child in
                    HStack(spacing: 5) {
                        Image(systemName: child.isDone ? "checkmark" : "circle")
                            .font(.system(size: 7))
                            .foregroundStyle(child.isDone ? Theme.ok : Theme.textFaint)
                        Text(child.text)
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                    }
                    .padding(.leading, 12)
                }
            }
            HStack(spacing: 6) {
                Text(URL(fileURLWithPath: task.sourcePath).lastPathComponent)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textFaint)
                if state != .unassigned {
                    Text(state.label)
                        .font(Theme.mono(9, .semibold))
                        .foregroundStyle(state.needsAttention ? Theme.warn : Theme.codex)
                }
                if !assignments.isEmpty {
                    Text("\(assignments.count) session")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.codex)
                }
                if gitTouched(task) {
                    TablerIcon(name: "git-commit", size: 9, color: Theme.warn)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.panelActive, in: RoundedRectangle(cornerRadius: 7))
        .onDrag { NSItemProvider(object: task.id as NSString) }
        .contextMenu { cardActions(task, in: document) }
        .accessibilityIdentifier("tasks.card.\(task.id)")
    }

    /// Whether the task's source file has uncommitted changes — a cheap "this
    /// area is being worked on" hint rather than a per-task diff.
    private func gitTouched(_ task: ProjectTask) -> Bool {
        gitChangedPaths.contains { task.sourcePath.hasSuffix($0) }
    }

    @State private var gitChangedPaths: [String] = []

    // MARK: - Sessions view

    private var sessionsView: some View {
        let grouped = Dictionary(grouping: metadata.document.assignments, by: \.sessionID)
        return VStack(alignment: .leading, spacing: 12) {
            if grouped.isEmpty {
                Text("Henüz bir göreve session atanmadı.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .panel()
            }
            ForEach(grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { sessionID in
                let assignments = grouped[sessionID] ?? []
                let record = projectStore.sessions.first { $0.id == sessionID }
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        selection = .session(sessionID)
                    } label: {
                        HStack(spacing: 8) {
                            if let record {
                                ProviderMark(provider: record.provider, size: 11)
                            }
                            Text(record?.displayTitle ?? String(sessionID.uuidString.prefix(8)))
                                .font(Theme.mono(11.5, .semibold))
                                .foregroundStyle(Theme.text)
                            Text("\(assignments.count) görev")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textFaint)
                            Spacer()
                            TablerIcon(name: "arrow-right", size: 11, color: Theme.textFaint)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tasks.session.\(sessionID.uuidString)")

                    ForEach(assignments) { assignment in
                        Divider().overlay(Theme.border)
                        HStack(spacing: 8) {
                            Text(assignment.role.label)
                                .font(Theme.mono(9.5, .semibold))
                                .foregroundStyle(Theme.codex)
                                .frame(width: 70, alignment: .leading)
                            Text(taskText(assignment))
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer()
                            Text(assignment.state.label)
                                .font(Theme.mono(9.5, .semibold))
                                .foregroundStyle(
                                    assignment.state.needsAttention ? Theme.warn : Theme.textDim
                                )
                            if assignment.needsRelinking {
                                Text("Needs relinking")
                                    .font(Theme.mono(9, .semibold))
                                    .foregroundStyle(Theme.danger)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                }
                .panel()
            }
        }
    }

    private func taskText(_ assignment: TaskSessionAssignment) -> String {
        sources.document(for: assignment.sourcePath)?
            .task(id: assignment.taskID)?.text
            ?? "görev bulunamadı"
    }


    // MARK: - Card actions

    /// The actions a task offers, in one place so the list row and the kanban
    /// card cannot drift apart.
    @ViewBuilder
    private func cardActions(_ task: ProjectTask, in document: TaskDocument) -> some View {
        Button("Send to Agent…") { dispatchTarget = (task, document) }
        Button("Send to Agent (hızlı)") { sendToAgent(task, role: .implementer, reuseSession: true) }
        Button("Create New Session") { sendToAgent(task, role: .implementer, reuseSession: false) }
        Menu("Assign Existing Session") {
            let candidates = projectStore.sessions(for: project.id)
            if candidates.isEmpty {
                Text("Oturum yok")
            }
            ForEach(candidates) { record in
                Menu(record.displayTitle) {
                    ForEach(TaskAgentRole.allCases) { role in
                        Button(role.label) {
                            metadata.assign(
                                taskID: task.id, sourcePath: task.sourcePath,
                                sessionID: record.id, role: role,
                                fingerprint: task.fingerprint
                            )
                        }
                    }
                }
            }
        }
        let assignments = metadata.assignments(for: task.id)
        if !assignments.isEmpty {
            Menu("Open Session") {
                ForEach(assignments) { assignment in
                    Button(sessionLabel(assignment)) {
                        selection = .session(assignment.sessionID)
                    }
                }
            }
        }
        Button("Run with Orchestrator") {
            sendToAgent(task, role: .orchestrator, reuseSession: false)
        }

        Divider()

        Button("Request Review") {
            reviewOrTest(task, role: .reviewer, state: .reviewRequested)
        }
        Button("Run Tests") {
            reviewOrTest(task, role: .tester, state: .testsFailing)
        }
        Button("Mark Blocked") {
            metadata.setState(.blocked, taskID: task.id, detail: "Kullanıcı bloklandı olarak işaretledi")
        }
        if task.isDone {
            Button("Reopen") {
                metadata.setState(.queued, taskID: task.id)
                toggle(task, in: document)
            }
        } else {
            Button("Complete") {
                metadata.setState(.completed, taskID: task.id)
                toggle(task, in: document)
            }
        }

        Divider()

        Button("Show Source") { revealSource(task) }
        Button("Show Diff") { showDiff(task) }
        if assignments.contains(where: \.needsRelinking) {
            Divider()
            Button("Bu göreve yeniden bağla") {
                for assignment in assignments where assignment.needsRelinking {
                    metadata.rebind(assignmentID: assignment.id, to: task)
                }
            }
        }
    }


    /// Performs a dispatch the sheet configured: creates a worktree if asked,
    /// finds or creates the session, records the assignment, raises an attention
    /// row, and delivers the full task context.
    private func dispatch(
        _ request: TaskDispatchRequest,
        task: ProjectTask,
        document: TaskDocument
    ) {
        var worktreePath = request.worktreePath
        if request.createsWorktree, worktreePath == nil {
            let name = request.worktreeName ?? TaskPromptBuilder.worktreeName(for: task)
            switch GitService.createWorktree(repoPath: project.rootPath, name: name) {
            case .success(let worktree):
                worktreePath = worktree.path
            case .failure(let error):
                message = "Worktree oluşturulamadı: \(error.message)"
                return
            }
        }

        let record: SessionRecord
        if let sessionID = request.existingSessionID,
           let existing = projectStore.sessions.first(where: { $0.id == sessionID }) {
            record = existing
        } else {
            record = projectStore.createSession(
                projectID: project.id,
                provider: request.provider,
                accountID: request.accountID,
                title: "\(request.provider.rawValue): \(task.text)",
                worktreePath: worktreePath
            )
        }

        let assignment = metadata.assign(
            taskID: task.id,
            sourcePath: task.sourcePath,
            sessionID: record.id,
            role: request.role,
            worktreePath: worktreePath ?? record.worktreePath,
            fingerprint: task.fingerprint
        )
        metadata.setState(.agentStarting, assignmentID: assignment.id)

        // The assignment is worth surfacing: an agent just started on the user's
        // behalf, and the Attention Center is where that belongs.
        AttentionStore.shared.report(
            kind: .input,
            title: "\(project.name) › \(task.text)",
            detail: "\(request.role.label) olarak \(record.displayTitle) oturumuna atandı",
            projectID: project.id,
            sessionID: record.id,
            id: "task-assigned:\(assignment.id.uuidString)"
        )

        selection = .session(record.id)
        let prompt = TaskPromptBuilder.prompt(TaskPromptBuilder.context(
            for: task,
            in: document,
            project: project,
            role: request.role,
            worktreePath: worktreePath ?? record.worktreePath,
            permissionProfile: request.permissionProfile
        ))
        deliver(prompt: prompt, to: record)
    }

    private func sessionLabel(_ assignment: TaskSessionAssignment) -> String {
        let title = projectStore.sessions.first { $0.id == assignment.sessionID }?.displayTitle
            ?? String(assignment.sessionID.uuidString.prefix(8))
        return "\(assignment.role.label): \(title)"
    }

    /// Starts (or reuses) a session and hands it the task as a prompt. The task
    /// text and its heading chain are all the agent is told — Uncoil writes
    /// nothing of its own into the file.
    private func sendToAgent(_ task: ProjectTask, role: TaskAgentRole, reuseSession: Bool) {
        let provider = settings.defaultProvider
        let existing = reuseSession
            ? projectStore.sessions(for: project.id).first(where: {
                $0.provider == provider && sessionStore.status(of: $0.id) != .terminated
            })
            : nil
        let record = existing ?? projectStore.createSession(
            projectID: project.id,
            provider: provider,
            accountID: settings.defaultAccount(for: provider)?.id,
            title: "\(provider.rawValue): \(task.text)"
        )
        metadata.assign(
            taskID: task.id, sourcePath: task.sourcePath, sessionID: record.id,
            role: role, fingerprint: task.fingerprint
        )
        if let assignment = metadata.assignments(for: task.id)
            .first(where: { $0.sessionID == record.id && $0.role == role }) {
            metadata.setState(.agentStarting, assignmentID: assignment.id)
        }
        selection = .session(record.id)
        deliver(prompt: prompt(for: task, role: role), to: record)
    }

    private func reviewOrTest(
        _ task: ProjectTask,
        role: TaskAgentRole,
        state: ProjectTaskExecutionState
    ) {
        // Requesting a review or a test run is a state change plus a prompt; the
        // failing/awaiting state itself is set by whatever reports back.
        sendToAgent(task, role: role, reuseSession: false)
        if let assignment = metadata.assignments(for: task.id).first(where: { $0.role == role }) {
            metadata.setState(
                role == .reviewer ? .reviewRequested : .running,
                assignmentID: assignment.id
            )
        }
        _ = state
    }

    private func prompt(for task: ProjectTask, role: TaskAgentRole) -> String {
        let location = task.headingPath.isEmpty
            ? URL(fileURLWithPath: task.sourcePath).lastPathComponent
            : "\(URL(fileURLWithPath: task.sourcePath).lastPathComponent) › \(task.headingPath.joined(separator: " › "))"
        let body = task.rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        switch role {
        case .reviewer:
            return """
            \(location) altındaki şu görevi review et. Uygulama yapma, bulgularını bildir.

            \(body)
            """
        case .tester:
            return """
            \(location) altındaki şu görev için testleri çalıştır ve sonucu bildir.

            \(body)
            """
        case .orchestrator:
            return """
            \(location) altındaki şu görevi alt görevlere bölerek yürüt. Gerekirse alt oturum aç ve sonuçları bana bildir.

            \(body)
            """
        case .owner, .implementer, .observer:
            return """
            \(location) altındaki şu görevi uygula. Bitirdiğinde TODO.md'deki checkbox'ı işaretle.

            \(body)
            """
        }
    }

    private func deliver(prompt: String, to record: SessionRecord) {
        guard let project = projectStore.projects.first(where: { $0.id == record.projectID }) else {
            return
        }
        _ = TerminalRegistry.shared.terminal(
            for: record, project: project,
            account: settings.account(id: record.accountID),
            settings: settings, sessionStore: sessionStore,
            projectStore: projectStore
        )
        let sid = record.id
        let provider = record.provider
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, sessionStore.status(of: sid) == .terminated {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await TerminalRegistry.shared.submitText(prompt, for: sid, provider: provider)
        }
    }

    private func showDiff(_ task: ProjectTask) {
        let worktree = metadata.assignments(for: task.id).compactMap(\.worktreePath).first
        let path = worktree ?? project.rootPath
        let changed = gitChangedPaths.isEmpty ? "değişiklik yok" : gitChangedPaths.joined(separator: ", ")
        message = "\(URL(fileURLWithPath: path).lastPathComponent): \(changed)"
    }

    // MARK: - Actions

    private func refresh() {
        let tracked = metadata.trackedFingerprints(in: sources.allTasks)
        sources.refresh(trackedFingerprints: tracked)
        metadata.markNeedsRelinking(assignmentIDs: sources.needsRelinking)
        watcher?.watch(paths: sources.sources.map(\.path) + [project.rootPath])
        let path = project.rootPath
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                GitService.snapshot(repoPath: path)
            }.value
            gitChangedPaths = snapshot.changedFiles.map(\.path)
        }
    }

    private func toggle(_ task: ProjectTask, in document: TaskDocument) {
        write(
            patches: [TodoEditor.togglePatch(for: task)],
            task: task,
            document: document,
            rebuild: { [TodoEditor.togglePatch(for: $0)] }
        )
    }

    private func commitRename(_ task: ProjectTask, in document: TaskDocument) {
        let newText = editingText
        editingTaskID = nil
        guard let patch = TodoEditor.renamePatch(for: task, to: newText) else { return }
        write(
            patches: [patch],
            task: task,
            document: document,
            rebuild: { TodoEditor.renamePatch(for: $0, to: newText).map { [$0] } ?? [] }
        )
    }

    private func handleDrop(
        _ providers: [NSItemProvider],
        to column: TaskBoardMapping.Column,
        in document: TaskDocument
    ) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let taskID = object as? String else { return }
            Task { @MainActor in
                guard let task = document.task(id: taskID),
                      task.headingPath.last != column.heading else { return }
                do {
                    let patches = try TodoEditor.movePatches(
                        task: task, to: [column.heading], in: document
                    )
                    write(
                        patches: patches, task: task, document: document,
                        // A move is recomputed from scratch rather than replayed.
                        rebuild: { _ in [] }
                    )
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        return true
    }

    /// Single write path: patches go through `TodoEditor`, a stale file is
    /// recomputed, and a conflict marks the task read-only until the user acts.
    private func write(
        patches: [TodoEditor.Patch],
        task: ProjectTask,
        document: TaskDocument,
        rebuild: @escaping (ProjectTask) -> [TodoEditor.Patch]
    ) {
        do {
            let outcome = try TodoEditor.write(
                patches: patches,
                to: document.path,
                expectedHash: document.contentHash,
                rebuild: TodoEditor.rebuilder(for: task, makePatches: rebuild),
                backupDirectory: ProjectStore.defaultDirectory()
                    .appendingPathComponent("todo-backups", isDirectory: true)
            )
            switch outcome {
            case .written:
                conflictTaskIDs.remove(task.id)
            case .recomputed:
                conflictTaskIDs.remove(task.id)
                message = "Dosya dışarıdan değişmişti; düzenleme güncel içerik üzerinde uygulandı."
            case .conflict(let detail):
                conflictTaskIDs.insert(task.id)
                message = "\(detail) Yeniden yükleyip tekrar dene."
            }
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    private func revealSource(_ task: ProjectTask) {
        // The editor is opened at the file; the line is shown so the user can
        // jump there even when the editor does not accept a line argument.
        settings.preferredEditor.open(URL(fileURLWithPath: task.sourcePath))
        message = "\(URL(fileURLWithPath: task.sourcePath).lastPathComponent):\(task.lineRange.startLine)"
    }
}

private struct EmptyTaskList: View {
    let isFiltered: Bool

    var body: some View {
        Text(isFiltered ? "Filtreye uyan görev yok." : "Görev yok.")
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textFaint)
            .frame(maxWidth: .infinity, minHeight: 100)
            .panel()
    }
}
