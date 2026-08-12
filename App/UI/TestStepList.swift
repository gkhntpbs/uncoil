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

    /// Nil means the user has not chosen yet, not "show everything" — that
    /// distinction is what lets the default follow the run while leaving `All`
    /// a filter the user can actually pick. Without it, choosing `All` on a
    /// failed run fell straight back to the failures.
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
            if record.summary.isDetailed, !record.cases.isEmpty {
                filterBar
                TestStepRows(cases: visibleCases, suiteID: suite.id) { opened = $0 }
            }
            if !record.artifacts.isEmpty {
                runArtifacts
            }
            if !record.logTail.isEmpty {
                outputSection
            }
        }
        .accessibilityIdentifier("tests.details.\(suite.id)")
        .task {
            // Deterministic entry for a UI test, and for looking at the window
            // without hunting for a row to click.
            if LaunchConfig.shared.testsStep == suite.id {
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

    private var filterBar: some View {
        HStack(spacing: 6) {
            // A filter for a bucket that is empty is a control that can only
            // produce an empty list, so it is not offered. `All` always is.
            ForEach(Filter.allCases.filter { $0 == .all || count($0) > 0 }) { option in
                chip(option)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ option: Filter) -> some View {
        let isOn = activeFilter == option
        let tint = option.outcome.map(Self.tint) ?? Theme.textDim
        return Button {
            filter = option
        } label: {
            HStack(spacing: 5) {
                Text(option.label)
                Text("\(count(option))")
                    .foregroundStyle(isOn ? tint : Theme.textFaint)
                    .monospacedDigit()
            }
            .font(Theme.mono(.micro, isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? tint : Theme.textDim)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                isOn ? tint.opacity(0.14) : Theme.statusSurface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .strokeBorder(isOn ? tint.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tests.filter.\(suite.id).\(option.rawValue)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
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

/// The rows themselves, in their bordered box.
///
/// Shared by the finished run and the one in flight: a step should not change
/// shape the moment its suite ends.
struct TestStepRows: View {
    let cases: [TestCaseResult]
    let suiteID: String
    var onOpen: ((TestCaseResult) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Keyed by position, not by name: two packages can report a test
            // of the same name, and a duplicated identity drops rows.
            ForEach(cases.indices, id: \.self) { index in
                if index > 0 {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
                TestStepRow(result: cases[index], suiteID: suiteID, onOpen: onOpen)
            }
        }
        .background(Theme.bg.opacity(0.35))
        // Clipped, not just backed: a failed row is tinted edge to edge, and
        // without this its square corner sits outside the rounded border.
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1)
        )
    }
}

/// One test, as a row.
private struct TestStepRow: View {
    let result: TestCaseResult
    let suiteID: String
    let onOpen: ((TestCaseResult) -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Aligned to the first line's baseline rather than to the top of a
            // box whose height depends on whether there is a message under it.
            TablerIcon(
                name: TestStepList.icon(result.outcome), size: 12,
                color: TestStepList.tint(result.outcome)
            )
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !result.suite.isEmpty {
                    Text(result.suite)
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let message = result.message, !message.isEmpty {
                    Text(message)
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.danger)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !result.artifacts.isEmpty {
                    TestArtifactCountLabel(count: result.artifacts.count)
                }
            }
            Spacer(minLength: 8)
            if let duration = result.duration {
                Text(TestStepFormat.duration(duration))
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
                    // A fixed column, so the times read as a column instead of
                    // stepping in and out with the length of each number.
                    .frame(width: 54, alignment: .trailing)
            }
            if onOpen != nil {
                TablerIcon(
                    name: "chevron-right", size: 11,
                    color: hovering ? Theme.textDim : Theme.textFaint.opacity(0.4)
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen?(result) }
        .contextMenu {
            Button("Copy name") { copy(result.id) }
            if let message = result.message, !message.isEmpty {
                Button("Copy failure message") { copy(message) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tests.step.\(suiteID).\(result.id)")
    }

    /// A failure is tinted for the same reason it is listed first: it is what
    /// the eye should land on. Everything else stays quiet, and only lifts
    /// under the pointer.
    private var rowBackground: Color {
        if result.outcome == .failed {
            return hovering ? Theme.danger.opacity(0.22) : Theme.dangerSurface
        }
        return hovering ? Theme.panelHover.opacity(0.6) : .clear
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
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.roomy) {
                    failureSection
                    if !result.artifacts.isEmpty {
                        section(String(localized: "Files")) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(result.artifacts) { artifact in
                                    artifactRow(artifact)
                                }
                            }
                        }
                    }
                    runSection
                }
                .padding(Theme.Space.roomy)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .uncoilScrollers()
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 620, height: 520)
        .background(Theme.bg)
        .accessibilityIdentifier("tests.stepDetail")
    }

    @ViewBuilder
    private var failureSection: some View {
        if let message = result.message, !message.isEmpty {
            section(String(localized: "Failure")) {
                Text(message)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.dangerSurface, in: RoundedRectangle(cornerRadius: 8))
            }
        } else if result.outcome == .failed {
            // Said plainly rather than left blank: the reason is missing
            // because this framework's failures are not parsed, not because
            // the test failed quietly.
            section(String(localized: "Failure")) {
                Text("This framework's failure output is not parsed, so there is no message to show — the run's own output is under the suite.")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runSection: some View {
        section(String(localized: "The run")) {
            VStack(alignment: .leading, spacing: 6) {
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
                detail(String(localized: "Result"), resultLine)
            }
        }
    }

    private var resultLine: String {
        guard record.summary.isDetailed else {
            return record.summary.didPass
                ? String(localized: "Passed") : String(localized: "Failed")
        }
        return "\(record.summary.passed) passed · \(record.summary.failed) failed"
            + " · \(record.summary.skipped) skipped"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            TablerIcon(
                name: TestStepList.icon(result.outcome), size: 16,
                color: TestStepList.tint(result.outcome)
            )
            .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name)
                    .font(Theme.mono(.large, .bold))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if !result.suite.isEmpty {
                        Text(result.suite)
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let duration = result.duration {
                        Text(TestStepFormat.duration(duration))
                            .foregroundStyle(Theme.textFaint)
                            .monospacedDigit()
                    }
                }
                .font(Theme.mono(.micro))
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.roomy)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Only a failure can be repaired; offering it on a green test would
            // be a button with nothing to say.
            if result.outcome == .failed, let project {
                Button {
                    TestRepair.dispatch(
                        project: project, suite: suite, record: record, focus: result,
                        projectStore: projectStore, provider: settings.defaultProvider,
                        language: settings.language.resolvedAgent()
                    )
                    // The new session is what the user should be looking at.
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        TablerIcon(name: "wand", size: 11, color: Theme.textOnHighlight)
                        Text("Fix with agent")
                            .font(Theme.mono(.micro, .semibold))
                            .foregroundStyle(Theme.textOnHighlight)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        Theme.highlight, in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tests.stepDetail.repair")
            }
            Button("Copy name") { copy(result.id) }
                .buttonStyle(.pressable)
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textDim)
            if let message = result.message, !message.isEmpty {
                Button("Copy failure") { copy(message) }
                    .buttonStyle(.pressable)
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(Theme.Space.roomy)
    }

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Theme.mono(.micro, .semibold))
                .foregroundStyle(Theme.textFaint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(Theme.mono(.micro))
                .foregroundStyle(Theme.textDim)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func artifactRow(_ artifact: TestArtifact) -> some View {
        Button {
            if artifact.kind.isPreviewable {
                onOpenArtifact(artifact)
            } else {
                NSWorkspace.shared.open(artifact.url)
            }
        } label: {
            HStack(spacing: 10) {
                thumbnail(artifact)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.name)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(artifact.path)
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tests.stepDetail.artifact.\(artifact.name)")
    }

    @ViewBuilder
    private func thumbnail(_ artifact: TestArtifact) -> some View {
        if artifact.kind.isPreviewable, let image = NSImage(contentsOf: artifact.url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.statusSurface)
                .frame(width: 64, height: 44)
                .overlay(
                    TablerIcon(
                        name: artifact.kind == .video ? "video" : "file",
                        size: 14, color: Theme.textFaint
                    )
                )
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
