import SwiftUI

/// The project screen's Tests area.
///
/// Peer of the Run area and deliberately shaped differently: a run is watched
/// while it happens, a suite is looked at once it is done. So the last result
/// is what the screen leads with, and it is there before anything is run —
/// results outlive the app.
struct ProjectTestsView: View {
    let project: Project

    @ObservedObject private var registry = TestRegistry.shared
    @State private var suites: [TestSuiteConfiguration] = []
    @State private var problems: [String] = []
    @State private var expanded: Set<String> = []
    @State private var message: String?
    @State private var isDetecting = false

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
            ForEach(problems, id: \.self) { problem in
                Text(problem)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.warn)
            }
            if suites.isEmpty {
                emptyState
            } else {
                ForEach(suites) { suite in
                    suiteCard(suite)
                }
            }
        }
        .task(id: project.id) {
            reload()
            registry.loadPersistedResults(project: project)
            // A red suite opens itself: the screen leads with the last result,
            // and for a failure the result is the reason, not the word. Done
            // once per project so that collapsing it again sticks.
            expanded = Set(
                suites
                    .filter { registry.state(project: project, suiteID: $0.id).latest
                        .map { !$0.summary.didPass } ?? false
                    }
                    .map(\.id)
            )
            if let wanted = LaunchConfig.shared.testsRun,
               let suite = suites.first(where: { $0.id == wanted }) {
                expanded.insert(suite.id)
                run(suite)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tests.container")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("TEST SUITES")
                .font(Theme.mono(.micro, .semibold))
                .foregroundStyle(Theme.textFaint)
            if !suites.isEmpty {
                Text("\(suites.count)")
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            if isDetecting {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            ControlButton(
                iconName: "refresh",
                help: String(localized: "Look for test suites in this project"),
                identifier: "tests.detect"
            ) {
                detect()
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No test suites yet")
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.text)
            Text("Uncoil can look for the project's own test setup — a scheme, a Package.swift, go.mod, Cargo.toml, a package.json test script, or a pytest configuration. What it finds is written to .uncoil/tests.json, which you and your agents can edit.")
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: detect) { Text("Look for tests") }
                .buttonStyle(AccentButtonStyle())
                .accessibilityIdentifier("tests.detectEmpty")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func suiteCard(_ suite: TestSuiteConfiguration) -> some View {
        let state = registry.state(project: project, suiteID: suite.id)
        let isExpanded = expanded.contains(suite.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                verdict(state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suite.name)
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.text)
                    Text(suite.command)
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if state.isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    ControlButton(
                        iconName: "player-stop",
                        help: String(localized: "Stop"),
                        identifier: "tests.stop.\(suite.id)",
                        tint: Theme.danger
                    ) {
                        registry.stop(project: project, suiteID: suite.id)
                    }
                } else {
                    ControlButton(
                        iconName: "player-play",
                        help: String(localized: "Run \(suite.name)"),
                        identifier: "tests.run.\(suite.id)",
                        tint: Theme.ok
                    ) {
                        run(suite)
                    }
                }
                if state.latest != nil {
                    ControlButton(
                        iconName: isExpanded ? "chevron-up" : "chevron-down",
                        help: isExpanded
                            ? String(localized: "Hide the results")
                            : String(localized: "Show the results"),
                        identifier: "tests.expand.\(suite.id)"
                    ) {
                        if isExpanded { expanded.remove(suite.id) } else { expanded.insert(suite.id) }
                    }
                }
            }
            if state.isRunning {
                running(state, suite: suite)
            }
            if let record = state.latest {
                summaryLine(record, suite: suite)
                if isExpanded {
                    TestStepList(record: record, suite: suite)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tests.suite.\(suite.id)")
    }

    /// What the suite is doing right now.
    ///
    /// The steps arrive as the runner prints them, so a long suite is watchable
    /// rather than a spinner with a log under it. Only the last few are shown:
    /// during a run the interesting end of the list is the recent end, and the
    /// whole of it is there the moment the run finishes.
    @ViewBuilder
    private func running(_ state: TestSuiteState, suite: TestSuiteConfiguration) -> some View {
        let live = state.liveCases
        if live.isEmpty {
            // Either nothing has been reported yet, or this framework's output
            // is not parsed at all — in both cases the output is what there is.
            if !state.logTail.isEmpty {
                Text(lastLines(state.logTail, 4))
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(4)
                    .padding(.leading, 16)
            }
        } else {
            let summary = state.liveSummary
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("\(summary.total) so far")
                        .foregroundStyle(Theme.textDim)
                    if summary.failed > 0 {
                        Text("\(summary.failed) failed").foregroundStyle(Theme.danger)
                    }
                    if let startedAt = state.startedAt {
                        // On its own clock: the rest of this view redraws when
                        // output arrives, and a suite that goes quiet for a
                        // minute would otherwise show a frozen elapsed time.
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(TestStepFormat.duration(
                                context.date.timeIntervalSince(startedAt)
                            ))
                            .foregroundStyle(Theme.textFaint)
                            .monospacedDigit()
                        }
                    }
                }
                .font(Theme.mono(.micro))
                TestStepRows(cases: Array(live.suffix(8)), suiteID: suite.id)
            }
            .padding(.leading, 16)
            .accessibilityIdentifier("tests.live.\(suite.id)")
        }
    }

    /// The at-a-glance answer. A suite that has never run gets a hollow ring
    /// rather than a grey tick: "not run" is not "passed with nothing in it".
    @ViewBuilder
    private func verdict(_ state: TestSuiteState) -> some View {
        if state.isRunning {
            Circle().fill(Theme.highlight).frame(width: 8, height: 8)
        } else if let record = state.latest {
            Circle()
                .fill(record.summary.didPass ? Theme.ok : Theme.danger)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .strokeBorder(Theme.textFaint, lineWidth: 1)
                .frame(width: 8, height: 8)
        }
    }

    private func summaryLine(_ record: TestRunRecord, suite: TestSuiteConfiguration) -> some View {
        HStack(spacing: 8) {
            if record.summary.isDetailed {
                Text("\(record.summary.passed) passed")
                    .foregroundStyle(Theme.ok)
                if record.summary.failed > 0 {
                    Text("\(record.summary.failed) failed").foregroundStyle(Theme.danger)
                }
                if record.summary.skipped > 0 {
                    Text("\(record.summary.skipped) skipped").foregroundStyle(Theme.textDim)
                }
            } else {
                // Saying "0 failures" here would be a claim the output never
                // made: nothing parsed it, and all that is known is the status.
                Text(record.summary.didPass ? "Passed" : "Failed")
                    .foregroundStyle(record.summary.didPass ? Theme.ok : Theme.danger)
                Text("(\(suite.framework.displayName) — no per-test detail)")
                    .foregroundStyle(Theme.textFaint)
            }
            if let duration = record.duration {
                Text(TestStepFormat.duration(duration)).foregroundStyle(Theme.textFaint)
            }
            if !record.allArtifacts.isEmpty {
                HStack(spacing: 3) {
                    TablerIcon(name: "photo", size: 9, color: Theme.textFaint)
                    Text("\(record.allArtifacts.count)")
                }
                .foregroundStyle(Theme.textFaint)
            }
            if let finished = record.finishedAt {
                Text(RelativeClock.short(since: finished)).foregroundStyle(Theme.textFaint)
            }
        }
        .font(Theme.mono(.micro))
        .padding(.leading, 16)
    }

    private func lastLines(_ text: String, _ count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(count).joined(separator: "\n")
    }

    // MARK: - Actions

    private func reload() {
        let contents = TestConfigFile.load(projectRoot: project.rootURL)
        suites = contents.suites
        problems = contents.problems
    }

    private func detect() {
        guard !isDetecting else { return }
        isDetecting = true
        message = nil
        let root = project.rootURL
        Task { @MainActor in
            let existing = TestConfigFile.load(projectRoot: root).suites
            let suggestions = await Task.detached(priority: .userInitiated) {
                TestDetection.detect(fileSystem: DiskRunDetectionFileSystem(root: root))
            }.value
            let merged = TestConfigFile.merge(
                existing: existing, suggestions: suggestions, replacingDetected: false
            )
            do {
                try TestConfigFile.save(merged, projectRoot: root)
            } catch {
                message = String(localized: "Could not write .uncoil/tests.json: \(error.localizedDescription)")
            }
            let added = Set(merged.map(\.id)).subtracting(existing.map(\.id))
            if added.isEmpty, merged.isEmpty {
                message = String(localized: "Nothing found. Add a suite to .uncoil/tests.json by hand, or ask an agent to.")
            } else if added.isEmpty {
                message = String(localized: "Nothing new.")
            } else {
                message = String(localized: "Added \(added.count).")
            }
            reload()
            registry.loadPersistedResults(project: project)
            isDetecting = false
        }
    }

    private func run(_ suite: TestSuiteConfiguration) {
        let project = project
        Task { @MainActor in
            await TestRegistry.shared.run(project: project, suite: suite)
        }
    }
}
