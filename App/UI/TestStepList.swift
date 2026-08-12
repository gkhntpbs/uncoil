import AppKit
import SwiftUI

/// The steps of one test run, in the order the runner reported them.
///
/// A suite's verdict is one word; this is the part that says why. Each row is
/// one test: what it was, how it went, how long it took, and — for a failure —
/// the message the runner printed, in place rather than buried in a log tail
/// the user has to scroll. A row opens onto the whole of it.
///
/// Failures lead by default. A run of four hundred green rows with one red one
/// in it hides exactly the row that matters, so the filter starts on what
/// failed whenever anything did.
struct TestStepList: View {
    let record: TestRunRecord
    let suite: TestSuiteConfiguration
    /// Whose project this is — the sheet needs it to find an agent to hand a
    /// failing test to.
    var project: Project?
    /// Owned by the card, because the chevron that toggles it sits in the
    /// summary bar and the card decides which suites start open.
    @Binding var isExpanded: Bool

    /// Nil means the user has not chosen yet, not "show everything" — that
    /// distinction is what lets the default follow the run while leaving `All`
    /// a filter the user can actually pick. Without it, choosing `All` on a
    /// failed run fell straight back to the failures.
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var filter: Filter?
    @State private var preview: TestArtifact?
    @State private var opened: TestCaseResult?
    @State private var showsOutput = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, failed, passed, skipped
        var id: String { rawValue }

        var outcome: TestCaseResult.Outcome? {
            switch self {
            case .all: nil
            case .failed: .failed
            case .passed: .passed
            case .skipped: .skipped
            }
        }

        var label: String {
            switch self {
            case .all: String(localized: "All")
            case .failed: String(localized: "Failed")
            case .passed: String(localized: "Passed")
            case .skipped: String(localized: "Skipped")
            }
        }
    }

    private var activeFilter: Filter {
        filter ?? Self.defaultFilter(for: record.summary)
    }

    /// What the list shows before anyone chooses: the failures, when there are
    /// any. A separate function because it is the rule the bug lived in — the
    /// chosen filter used to be indistinguishable from no choice at all, so
    /// picking `All` on a failed run fell straight back to `Failed`.
    static func defaultFilter(for summary: TestRunSummary) -> Filter {
        summary.failed > 0 ? .failed : .all
    }

    static func visible(_ cases: [TestCaseResult], filter: Filter) -> [TestCaseResult] {
        guard let outcome = filter.outcome else { return cases }
        return cases.filter { $0.outcome == outcome }
    }

    private var visibleCases: [TestCaseResult] {
        Self.visible(record.cases, filter: activeFilter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            TestSummaryBar(
                // Skipped tests were never run, so they are not part of what
                // got done — only of what there was.
                done: record.summary.passed + record.summary.failed,
                total: record.summary.total,
                totalIsEstimate: false,
                summary: record.summary,
                selection: record.summary.isDetailed ? $filter : nil,
                counts: { count($0) },
                isExpanded: $isExpanded,
                identifierPrefix: "tests.filter.\(suite.id)",
                trailing: { meta }
            )
            if isExpanded {
                if showsSuiteRepair, let project {
                    repairButton(project)
                }
                if record.summary.isDetailed, !record.cases.isEmpty {
                    TestStepRows(
                        cases: visibleCases,
                        suiteID: suite.id,
                        onOpen: { opened = $0 },
                        onRepair: project.map { project in
                            { result in
                                TestRepair.dispatch(
                                    project: project, suite: suite, record: record, focus: result,
                                    projectStore: projectStore, provider: settings.defaultProvider,
                                    language: settings.language.resolvedAgent()
                                )
                            }
                        }
                    )
                }
                if !record.artifacts.isEmpty {
                    runArtifacts
                }
                if record.cases.isEmpty, !record.logTail.isEmpty {
                    // The only case the raw output is still shown in: a run
                    // with no steps has nothing else to show, and hiding it
                    // would leave the drawer empty. Everywhere else the output
                    // belongs to a step, and lives in the step's own window.
                    outputSection
                }
            }
        }
        .accessibilityIdentifier("tests.details.\(suite.id)")
        .task {
            // Deterministic entry for a UI test, and for looking at the window
            // without hunting for a row to click.
            if LaunchConfig.shared.testsStep == suite.id {
                isExpanded = true
                opened = visibleCases.first
            }
        }
        .sheet(item: $preview) { artifact in
            TestArtifactPreview(artifact: artifact)
        }
        .sheet(item: $opened) { result in
            TestStepDetailSheet(
                result: result, record: record, suite: suite, project: project,
                onOpenArtifact: { artifact in
                    opened = nil
                    preview = artifact
                }
            )
        }
    }

    /// What the run cost and when it was: the right-hand end of the summary
    /// bar, where a number that is not a tally belongs.
    private var meta: some View {
        HStack(spacing: Theme.Space.tight) {
            if !record.summary.isDetailed {
                // Saying "0 failures" here would be a claim the output never
                // made: nothing parsed it, and all that is known is the status.
                Text(record.summary.didPass ? "Passed" : "Failed")
                    .foregroundStyle(record.summary.didPass ? Theme.ok : Theme.danger)
                Text("no per-test detail").foregroundStyle(Theme.textFaint)
            }
            if !record.allArtifacts.isEmpty {
                HStack(spacing: 3) {
                    TablerIcon(name: "photo", size: 10, color: Theme.textFaint)
                    Text("\(record.allArtifacts.count)")
                }
                .foregroundStyle(Theme.textFaint)
            }
            if let duration = record.duration {
                Text(TestStepFormat.duration(duration))
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
            }
            if let finished = record.finishedAt {
                Text(RelativeClock.short(since: finished)).foregroundStyle(Theme.textFaint)
            }
        }
        .font(Theme.mono(.small))
    }

    /// Offered only when there is no failing row to hand over instead: a run
    /// that failed without naming a test, or one where every test failed and
    /// picking one of them would be arbitrary. Anywhere else the wand on the
    /// row is the better handle, because it says which test it means.
    static func showsSuiteRepair(for record: TestRunRecord) -> Bool {
        guard !record.summary.didPass else { return false }
        let failed = record.cases.count { $0.outcome == .failed }
        return failed == 0 || failed == record.cases.count
    }

    private var showsSuiteRepair: Bool { Self.showsSuiteRepair(for: record) }

    /// The whole suite handed over at once. One test at a time is offered on
    /// the row itself, where the test is.
    private func repairButton(_ project: Project) -> some View {
        Button {
            TestRepair.dispatch(
                project: project, suite: suite, record: record,
                projectStore: projectStore, provider: settings.defaultProvider,
                language: settings.language.resolvedAgent()
            )
        } label: {
            HStack(spacing: 5) {
                TablerIcon(name: "wand", size: 11, color: Theme.textOnHighlight)
                Text("Fix with agent")
                    .font(Theme.mono(.small, .semibold))
                    .foregroundStyle(Theme.textOnHighlight)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.highlight, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.pressable)
        .help(String(localized: "Open a new agent session on these failures"))
        .accessibilityIdentifier("tests.repair.\(suite.id)")
    }

    // MARK: - Filters

    /// Counted from the rows themselves rather than from the run's summary.
    ///
    /// The two can disagree — a summary carries the runner's own totals, while
    /// the list carries the tests whose names were actually recovered — and a
    /// filter whose number does not match the rows it produces is a filter
    /// nobody trusts twice.
    private func count(_ filter: Filter) -> Int {
        guard let outcome = filter.outcome else { return record.cases.count }
        return record.cases.count { $0.outcome == outcome }
    }

    static func tint(_ outcome: TestCaseResult.Outcome) -> Color {
        switch outcome {
        case .passed: Theme.ok
        case .failed: Theme.danger
        case .skipped: Theme.textDim
        }
    }

    static func icon(_ outcome: TestCaseResult.Outcome) -> String {
        switch outcome {
        case .passed: "circle-check"
        case .failed: "circle-x"
        case .skipped: "circle-minus"
        }
    }

    // MARK: - Leftovers

    /// Files the run wrote that no single test claimed — a report, a recording
    /// of the whole session. Shown rather than dropped: the suite produced them
    /// on purpose.
    private var runArtifacts: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("From this run")
                .font(Theme.mono(.micro, .semibold))
                .foregroundStyle(Theme.textFaint)
            TestArtifactStrip(artifacts: record.artifacts) { preview = $0 }
        }
    }

    /// The raw output, behind a disclosure of the app's own making — the system
    /// one brings its own chevron, its own indent and its own animation, none
    /// of which match anything else on this screen.
    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                showsOutput.toggle()
            } label: {
                HStack(spacing: 5) {
                    TablerIcon(
                        name: showsOutput ? "chevron-down" : "chevron-right",
                        size: 10, color: Theme.textFaint
                    )
                    Text("Output")
                        .font(Theme.mono(.micro, .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tests.output.\(suite.id)")
            if showsOutput {
                Text(
                    record.logTail
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .suffix(record.summary.isDetailed ? 40 : 200)
                        .joined(separator: "\n")
                )
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1)
                )
            }
        }
    }
}

/// The steps of a run, as rows.
///
/// Shared by the finished run and the one in flight: a step should not change
/// shape the moment its suite ends.
struct TestStepRows: View {
    let cases: [TestCaseResult]
    let suiteID: String
    var onOpen: ((TestCaseResult) -> Void)?
    /// Offered on a failed row when the list knows who to hand it to.
    var onRepair: ((TestCaseResult) -> Void)?

    var body: some View {
        VStack(spacing: 4) {
            // Keyed by position, not by name: two packages can report a test
            // of the same name, and a duplicated identity drops rows.
            ForEach(cases.indices, id: \.self) { index in
                row(cases[index])
            }
        }
    }

    private func row(_ result: TestCaseResult) -> some View {
        EntityRow(
            title: result.name,
            subtitle: result.outcome == .failed ? nil : result.suite,
            detail: result.outcome == .failed ? (result.message ?? result.suite) : nil,
            detailColor: result.message == nil ? Theme.textFaint : Theme.danger,
            ring: ring(result.outcome),
            tint: result.outcome == .failed ? Theme.danger : nil,
            identifier: "tests.step.\(suiteID).\(result.id)",
            onTap: onOpen.map { open in { open(result) } }
        ) {
            HStack(spacing: Theme.Space.tight) {
                if !result.artifacts.isEmpty {
                    HStack(spacing: 3) {
                        TablerIcon(name: "photo", size: 10, color: Theme.textFaint)
                        Text("\(result.artifacts.count)")
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textFaint)
                    }
                }
                if let duration = result.duration {
                    Text(TestStepFormat.duration(duration))
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .monospacedDigit()
                        // A fixed column, so the times read as a column instead
                        // of stepping in and out with the length of each number.
                        .frame(width: 52, alignment: .trailing)
                }
                if result.outcome == .failed, let onRepair {
                    MiniActionButton(
                        iconName: "wand",
                        help: String(localized: "Open a new agent session on this test"),
                        identifier: "tests.step.repair.\(result.id)"
                    ) {
                        onRepair(result)
                    }
                }
                if onOpen != nil {
                    TablerIcon(name: "chevron-right", size: 11, color: Theme.textFaint)
                }
            }
        }
        .contextMenu {
            Button("Copy name") { copy(result.id) }
            if let message = result.message, !message.isEmpty {
                Button("Copy failure message") { copy(message) }
            }
        }
    }

    private func ring(_ outcome: TestCaseResult.Outcome) -> StatusRing.State {
        switch outcome {
        case .passed: .passed
        case .failed: .failed
        case .skipped: .skipped
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// What a step produced, as one quiet line — the files themselves are in the
/// step's own window, where there is room for their names.
private struct TestArtifactCountLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            TablerIcon(name: "photo", size: 10, color: Theme.textFaint)
            Text("\(count) files")
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textFaint)
        }
    }
}

/// The files one run produced, as a row of small buttons.
private struct TestArtifactStrip: View {
    let artifacts: [TestArtifact]
    let onOpen: (TestArtifact) -> Void

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(artifacts) { artifact in
                Button {
                    // Only an image can be shown in place. Anything else is
                    // handed to the app that actually understands it.
                    if artifact.kind.isPreviewable {
                        onOpen(artifact)
                    } else {
                        NSWorkspace.shared.open(artifact.url)
                    }
                } label: {
                    HStack(spacing: 5) {
                        TablerIcon(name: iconName(artifact), size: 11, color: Theme.textDim)
                        Text(artifact.name)
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        Theme.statusSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    )
                }
                .buttonStyle(.pressable)
                .help(artifact.path)
                .accessibilityIdentifier("tests.artifact.\(artifact.name)")
            }
        }
    }

    private func iconName(_ artifact: TestArtifact) -> String {
        switch artifact.kind {
        case .image: "photo"
        case .video: "video"
        case .other: "file"
        }
    }
}

/// One step, in full: what it was, what it said, what it drew, and the run it
/// belonged to.
///
/// The row can only ever show the first lines of a message and the count of its
/// files; a failure worth reading is usually longer than a row. This is where
/// the whole of it lives, without sending the user to a log.
struct TestStepDetailSheet: View {
    let result: TestCaseResult
    let record: TestRunRecord
    let suite: TestSuiteConfiguration
    var project: Project?
    var onOpenArtifact: (TestArtifact) -> Void = { _ in }

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            StackedCard(inset: 0, overlap: 12) {
                header
            } drawer: {
                // One scroller, around everything. Boxes that scroll inside a
                // window that also scrolls are two gestures for one movement,
                // and each of them takes a fixed height whether it needs it or
                // not — which is what left a one-line failure in a tall red
                // block.
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.snug) {
                        failureSection
                        if !result.artifacts.isEmpty {
                            section(String(localized: "Files")) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(result.artifacts) { artifact in
                                        artifactRow(artifact)
                                    }
                                }
                            }
                        }
                        runSection
                        outputSection
                    }
                    .padding(.horizontal, Theme.Space.hair)
                    .padding(.bottom, Theme.Space.hair)
                }
                .uncoilScrollers()
            }
            .padding(Theme.Space.roomy)
        }
        .frame(width: 640, height: 560)
        .background(Theme.bg)
        .accessibilityIdentifier("tests.stepDetail")
    }

    /// The same head a suite card has: the ring, the name, and the one action
    /// worth taking from here.
    private var header: some View {
        HStack(spacing: Theme.Space.snug) {
            StatusRing(state: ring, size: 22, showsGlyph: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(Theme.mono(.large))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.tight) {
                    if !result.suite.isEmpty {
                        Text(result.suite)
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let duration = result.duration {
                        Text(TestStepFormat.duration(duration))
                            .foregroundStyle(Theme.textFaint)
                            .monospacedDigit()
                    }
                }
                .font(Theme.mono(.small))
            }
            Spacer(minLength: Theme.Space.snug)
            if result.outcome == .failed, let project {
                GlyphActionButton(
                    iconName: "wand",
                    help: String(localized: "Open a new agent session on this test"),
                    identifier: "tests.stepDetail.repair",
                    tint: Theme.highlight,
                    size: 18
                ) {
                    TestRepair.dispatch(
                        project: project, suite: suite, record: record, focus: result,
                        projectStore: projectStore, provider: settings.defaultProvider,
                        language: settings.language.resolvedAgent()
                    )
                    // The new session is what the user should be looking at.
                    dismiss()
                }
            }
            GlyphActionButton(
                iconName: "x",
                help: String(localized: "Close"),
                identifier: "tests.stepDetail.close",
                tint: Theme.textDim,
                size: 16
            ) {
                dismiss()
            }
        }
    }

    private var ring: StatusRing.State {
        switch result.outcome {
        case .passed: .passed
        case .failed: .failed
        case .skipped: .skipped
        }
    }

    @ViewBuilder
    private var failureSection: some View {
        if let message = result.message, !message.isEmpty {
            section(String(localized: "Failure")) {
                Text(Self.clamp(message, lines: 20))
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.snug)
                    .background(
                        Theme.dangerSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    )
            }
        } else if result.outcome == .failed {
            // Said plainly rather than left blank: the reason is missing
            // because this framework's failures are not parsed, not because
            // the test failed quietly.
            section(String(localized: "Failure")) {
                Text("This framework's failure output is not parsed, so there is no message to show — the run's own output is below.")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The run this step belonged to, as rows of the same shape the summary bar
    /// uses — the tally first, because it is the thing being asked about.
    private var runSection: some View {
        section(String(localized: "The run")) {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                TestSummaryBar(
                    done: record.summary.passed + record.summary.failed,
                    total: record.summary.total,
                    summary: record.summary,
                    identifierPrefix: "tests.stepDetail.summary"
                )
                VStack(alignment: .leading, spacing: 5) {
                    detail(String(localized: "Suite"), suite.name)
                    detail(String(localized: "Command"), suite.command)
                    detail(String(localized: "Framework"), suite.framework.displayName)
                    if let finished = record.finishedAt {
                        detail(
                            String(localized: "Finished"),
                            String(localized: "\(RelativeClock.short(since: finished)) ago")
                        )
                    }
                    if let duration = record.duration {
                        detail(String(localized: "Took"), TestStepFormat.duration(duration))
                    }
                    if let exitCode = record.exitCode {
                        detail(String(localized: "Exit code"), "\(exitCode)")
                    }
                }
                .padding(.horizontal, Theme.Space.hair)
            }
        }
    }

    /// The run's output, in the window where a step is being read rather than
    /// under the card where it was in everyone's way.
    @ViewBuilder
    private var outputSection: some View {
        if !record.logTail.isEmpty {
            section(String(localized: "Output")) {
                Text(Self.clamp(record.logTail, lines: 60, fromTheEnd: true))
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.snug)
                    .background(
                        Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.panel)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            }
        }
    }

    /// A block of text kept to a readable length. The window scrolls; a box
    /// inside it that also scrolls does not need to, and a box that takes a
    /// fixed height leaves a one-line message sitting in an empty frame.
    static func clamp(_ text: String, lines: Int, fromTheEnd: Bool = false) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let kept = fromTheEnd ? Array(all.suffix(lines)) : Array(all.prefix(lines))
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(Theme.mono(.micro, .semibold))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, Theme.Space.hair)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
            Text(label)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textDim)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func artifactRow(_ artifact: TestArtifact) -> some View {
        EntityRow(
            title: artifact.name,
            subtitle: artifact.path,
            identifier: "tests.stepDetail.artifact.\(artifact.name)",
            onTap: {
                if artifact.kind.isPreviewable {
                    onOpenArtifact(artifact)
                } else {
                    NSWorkspace.shared.open(artifact.url)
                }
            }
        ) {
            thumbnail(artifact)
        }
    }

    @ViewBuilder
    private func thumbnail(_ artifact: TestArtifact) -> some View {
        if artifact.kind.isPreviewable, let image = NSImage(contentsOf: artifact.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
        } else {
            TablerIcon(
                name: artifact.kind == .video ? "video" : "file",
                size: 14, color: Theme.textFaint
            )
            .frame(width: 56, height: 36)
        }
    }
}

/// An artifact image, at the size it actually is.
private struct TestArtifactPreview: View {
    let artifact: TestArtifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(spacing: 8) {
                Text(artifact.name)
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
                }
                .buttonStyle(.pressable)
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textDim)
                Button("Done") { dismiss() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
            }
            if let image = NSImage(contentsOf: artifact.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 900, maxHeight: 600)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1)
                    )
            } else {
                // The record outlives the file: a screenshot deleted between
                // runs should say so rather than show an empty frame.
                Text("The file is no longer at \(artifact.path)")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .padding(20)
            }
        }
        .padding(Theme.Space.roomy)
        .background(Theme.bg)
        .accessibilityIdentifier("tests.artifactPreview")
    }
}

/// Durations, written the way the header writes them.
enum TestStepFormat {
    /// Three scales, because one would misreport two of them: a test that
    /// takes three milliseconds is not `0.0s`, and a suite that takes seven
    /// minutes is not `420.0s`.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
