import SwiftUI

/// The project screen's Tests area.
///
/// Peer of the Run area and deliberately shaped differently: a run is watched
/// while it happens, a suite is looked at once it is done. So the last result
/// is what the screen leads with, and it is there before anything is run —
/// results outlive the app.
struct ProjectTestsView: View {
    let project: Project

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
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

    /// One suite: what it is, and what it did, tucked under it.
    private func suiteCard(_ suite: TestSuiteConfiguration) -> some View {
        let state = registry.state(project: project, suiteID: suite.id)
        let isExpanded = expanded.contains(suite.id)
        return StackedCard {
            head(suite, state: state)
        } drawer: {
            drawer(suite, state: state, isExpanded: isExpanded)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tests.suite.\(suite.id)")
    }

    /// The head: the suite's name and the one button that acts on it. Nothing
    /// that changes while it runs lives up here, so the card does not twitch
    /// under the pointer as results arrive.
    private func head(
        _ suite: TestSuiteConfiguration, state: TestSuiteState
    ) -> some View {
        HStack(spacing: Theme.Space.snug) {
            StatusRing(state: ring(state), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(suite.name)
                    .font(Theme.mono(.large))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(suite.command)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.snug)
            if state.isRunning {
                GlyphActionButton(
                    iconName: "player-pause",
                    help: String(localized: "Stop"),
                    identifier: "tests.stop.\(suite.id)",
                    tint: Theme.warn
                ) {
                    registry.stop(project: project, suiteID: suite.id)
                }
            } else {
                GlyphActionButton(
                    iconName: "player-play",
                    help: String(localized: "Run \(suite.name)"),
                    identifier: "tests.run.\(suite.id)",
                    tint: Theme.ok
                ) {
                    run(suite)
                }
            }
        }
    }

    private func ring(_ state: TestSuiteState) -> StatusRing.State {
        if state.isRunning { return .running }
        guard let record = state.latest else { return .idle }
        return record.summary.didPass ? .passed : .failed
    }

    /// The drawer: the tally, and — while it is open — the steps themselves.
    @ViewBuilder
    private func drawer(
        _ suite: TestSuiteConfiguration, state: TestSuiteState, isExpanded: Bool
    ) -> some View {
        if state.isRunning {
            running(state, suite: suite)
        } else if let record = state.latest {
            TestStepList(
                record: record, suite: suite, project: project,
                isExpanded: Binding(
                    get: { isExpanded },
                    set: { open in
                        if open { expanded.insert(suite.id) } else { expanded.remove(suite.id) }
                    }
                )
            )
        } else {
            // Never run. The drawer still exists, so the card does not change
            // shape the first time it is used.
            Text("Not run yet")
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, Theme.Space.hair)
                .frame(height: 20)
        }
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
        let summary = state.liveSummary
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            TestSummaryBar(
                done: summary.passed + summary.failed,
                // The total is unknown until the runner is finished, and the
                // last run's is a different run's number. Better a count that
                // is true than a fraction that is invented.
                total: 0,
                summary: summary,
                isLive: true,
                trailing: {
                    if let startedAt = state.startedAt {
                        // On its own clock: the rest of this view redraws when
                        // output arrives, and a suite that goes quiet for a
                        // minute would otherwise show a frozen elapsed time.
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(TestStepFormat.duration(
                                context.date.timeIntervalSince(startedAt)
                            ))
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textFaint)
                            .monospacedDigit()
                        }
                    }
                }
            )
            if live.isEmpty {
                // Either nothing has been reported yet, or this framework's
                // output is not parsed at all — the output is what there is.
                if !state.logTail.isEmpty {
                    Text(lastLines(state.logTail, 4))
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(4)
                        .padding(.horizontal, Theme.Space.hair)
                }
            } else {
                TestStepRows(cases: Array(live.suffix(6)), suiteID: suite.id)
            }
        }
        .accessibilityIdentifier("tests.live.\(suite.id)")
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
