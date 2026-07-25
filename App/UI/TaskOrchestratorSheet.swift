import SwiftUI

/// Starting agents on several tasks at once.
///
/// Replaces the old plan *alert*: the plan is shown as a searchable, selectable
/// list, the agent is chosen here, and "Başlat" is what actually dispatches —
/// nothing runs before it.
struct TaskOrchestratorSheet: View {
    let plan: OrchestratorPlan
    /// Every open task the plan could act on, in file order.
    let tasks: [ProjectTask]
    /// Called with what the user picked; the owner performs the dispatches.
    let onStart: ([ProjectTask], AgentProvider, AgentLaunchSelection, Bool) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @State private var query = ""
    @State private var selectedIDs: Set<String> = []
    @State private var provider: AgentProvider = .claude
    @State private var didSeed = false
    @State private var launch = AgentLaunchSelection.providerDefault
    @State private var autoStart = true
    @State private var capabilities = AgentLaunchCapabilities()

    /// What the plan would dispatch, by task id — used to preselect and to show
    /// why something was left out.
    private var plannedIDs: Set<String> { Set(plan.dispatches.map(\.taskID)) }

    private var skippedReasons: [String: String] {
        Dictionary(plan.skipped.map { ($0.taskID, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }

    private var visible: [ProjectTask] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return tasks }
        return tasks.filter {
            $0.text.localizedCaseInsensitiveContains(trimmed)
                || $0.headingPath.joined(separator: " ").localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            searchRow
            Divider().overlay(Theme.border)

            if tasks.isEmpty {
                Text("Başlatılacak açık görev yok.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(visible) { task in
                            row(task)
                            if task.id != visible.last?.id {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                    .uncoilScrollers()
                }
            }

            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 640, height: 560)
        .background(Theme.bg)
        .onAppear(perform: seedSelection)
        .task(id: provider) {
            // The pickers only offer what the chosen CLI was seen to support.
            launch = .providerDefault
            capabilities = await AgentLaunchCatalog.detect(
                provider: provider,
                binaryPath: settings.binaryPath(for: provider)
            )
        }
        .accessibilityIdentifier("tasks.orchestratorSheet")
    }

    /// The plan's choices become the starting selection: what the orchestrator
    /// would run is preselected, and the user narrows or widens from there.
    private func seedSelection() {
        guard !didSeed else { return }
        didSeed = true
        provider = settings.defaultProvider
        selectedIDs = plannedIDs.isEmpty
            ? Set(tasks.map(\.id))
            : plannedIDs.intersection(Set(tasks.map(\.id)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Görevleri agent'lara ver")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.text)
            Text("Seçtiğin her görev için bir oturum açılır ve görev prompt olarak gönderilir.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var searchRow: some View {
        HStack(spacing: 9) {
            TablerIcon(name: "search", size: 12, color: Theme.textFaint)
            TextField("Görev ara…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.text)
                .accessibilityIdentifier("tasks.orchestrator.search")
            Spacer()
            Button(selectedIDs.count == tasks.count ? "Hiçbirini seçme" : "Tümünü seç") {
                selectedIDs = selectedIDs.count == tasks.count ? [] : Set(tasks.map(\.id))
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func row(_ task: ProjectTask) -> some View {
        let isOn = selectedIDs.contains(task.id)
        let skipReason = skippedReasons[task.id]
        return Button {
            if isOn { selectedIDs.remove(task.id) } else { selectedIDs.insert(task.id) }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? Theme.highlight : Theme.textFaint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.text)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if !task.headingPath.isEmpty {
                            Text(task.headingPath.joined(separator: " › "))
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1)
                        }
                        // The plan's warnings ride along instead of vanishing
                        // with the old alert.
                        if let skipReason {
                            Text(skipReason)
                                .font(Theme.mono(9, .semibold))
                                .foregroundStyle(Theme.warn)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tasks.orchestrator.row.\(task.id)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 10) {
                Picker("", selection: $provider) {
                    ForEach([AgentProvider.claude, .codex], id: \.self) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("tasks.orchestrator.provider")

                if !capabilities.models.isEmpty {
                    Picker("", selection: Binding(
                        get: { launch.model }, set: { launch.model = $0 }
                    )) {
                        Text("Model: varsayılan").tag(String?.none)
                        ForEach(capabilities.models) { option in
                            Text(option.label).tag(String?.some(option.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("tasks.orchestrator.model")
                }

                if !capabilities.efforts.isEmpty {
                    Picker("", selection: Binding(
                        get: { launch.effort }, set: { launch.effort = $0 }
                    )) {
                        Text("Effort: varsayılan").tag(String?.none)
                        ForEach(capabilities.efforts) { option in
                            Text(option.label).tag(String?.some(option.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("tasks.orchestrator.effort")
                }

                Picker("", selection: Binding(
                    get: { launch.workingMode }, set: { launch.workingMode = $0 }
                )) {
                    Text("Mod: varsayılan").tag(AgentWorkingMode?.none)
                    ForEach(capabilities.workingModes) { mode in
                        Text(mode.label(for: provider)).tag(AgentWorkingMode?.some(mode))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("tasks.orchestrator.mode")

                Toggle(isOn: $autoStart) {
                    Text("Otomatik başlat")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("tasks.orchestrator.autoStart")
            }

            HStack(spacing: 9) {
                Text(
                    autoStart
                        ? "\(selectedIDs.count) görev seçili"
                        : "\(selectedIDs.count) görev seçili · prompt yazılır, Enter'a sen basarsın"
                )
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textFaint)

                Spacer()

                Button("Vazgeç", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                Button("\(provider.displayName) ile başlat (\(selectedIDs.count))") {
                    onStart(
                        tasks.filter { selectedIDs.contains($0.id) },
                        provider, launch, autoStart
                    )
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(selectedIDs.isEmpty)
                .accessibilityIdentifier("tasks.orchestrator.start")
            }
        }
        .padding(14)
    }
}
