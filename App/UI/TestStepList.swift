import AppKit
import SwiftUI

/// The steps of one test run, in the order the runner reported them.
///
/// A suite's verdict is one word; this is the part that says why. Each row is
/// one test: what it was, how it went, how long it took, and — for a failure —
/// the message the runner printed, in place rather than buried in a log tail
/// the user has to scroll.
///
/// Failures lead by default. A run of four hundred green rows with one red one
/// in it hides exactly the row that matters, so the filter starts on what
/// failed whenever anything did.
struct TestStepList: View {
    let record: TestRunRecord
    let suite: TestSuiteConfiguration

    @State private var filter: Filter?
    @State private var preview: TestArtifact?

    enum Filter: String, CaseIterable, Identifiable {
        case failed, passed, skipped
        var id: String { rawValue }

        var outcome: TestCaseResult.Outcome {
            switch self {
            case .failed: .failed
            case .passed: .passed
            case .skipped: .skipped
            }
        }

        var label: String {
            switch self {
            case .failed: String(localized: "Failed")
            case .passed: String(localized: "Passed")
            case .skipped: String(localized: "Skipped")
            }
        }
    }

    /// Nil until the user picks one, so the default can follow the run rather
    /// than being frozen at the moment the card was first drawn.
    private var activeFilter: Filter? {
        filter ?? (record.summary.failed > 0 ? .failed : nil)
    }

    private var visibleCases: [TestCaseResult] {
        guard let activeFilter else { return record.cases }
        return record.cases.filter { $0.outcome == activeFilter.outcome }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if record.summary.isDetailed, !record.cases.isEmpty {
                filterBar
                    .padding(.bottom, 6)
                steps
            }
            if !record.artifacts.isEmpty {
                runArtifacts
            }
            if !record.logTail.isEmpty {
                logTail
            }
        }
        .accessibilityIdentifier("tests.details.\(suite.id)")
        .sheet(item: $preview) { artifact in
            TestArtifactPreview(artifact: artifact)
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
        record.cases.count { $0.outcome == filter.outcome }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            chip(
                label: String(localized: "All"), count: record.cases.count,
                tint: Theme.textDim, isOn: activeFilter == nil, id: "all"
            ) {
                filter = nil
            }
            // A filter for a bucket that is empty is a control that can only
            // produce an empty list, so it is not offered.
            ForEach(Filter.allCases.filter { count($0) > 0 }) { option in
                chip(
                    label: option.label, count: count(option), tint: tint(option.outcome),
                    isOn: activeFilter == option, id: option.rawValue
                ) {
                    filter = activeFilter == option ? nil : option
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(
        label: String, count: Int, tint: Color, isOn: Bool, id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Text("\(count)").foregroundStyle(isOn ? tint : Theme.textFaint)
            }
            .font(Theme.mono(.micro, isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? tint : Theme.textDim)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                isOn ? tint.opacity(0.14) : Theme.statusSurface.opacity(0.5),
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tests.filter.\(suite.id).\(id)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleCases.enumerated()), id: \.element.id) { index, result in
                if index > 0 {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
                TestStepRow(result: result, suiteID: suite.id, onOpen: { preview = $0 })
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

    private func tint(_ outcome: TestCaseResult.Outcome) -> Color {
        switch outcome {
        case .passed: Theme.ok
        case .failed: Theme.danger
        case .skipped: Theme.textDim
        }
    }

    // MARK: - Leftovers

    /// Files the run wrote that no single test claimed — a report, a recording
    /// of the whole session. Shown rather than dropped: the suite produced them
    /// on purpose.
    private var runArtifacts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From this run")
                .font(Theme.mono(.micro, .semibold))
                .foregroundStyle(Theme.textFaint)
            TestArtifactStrip(artifacts: record.artifacts, onOpen: { preview = $0 })
        }
        .padding(.top, 8)
    }

    private var logTail: some View {
        DisclosureGroup {
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
            .padding(8)
            .background(Theme.bg.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        } label: {
            Text("Output")
                .font(Theme.mono(.micro, .semibold))
                .foregroundStyle(Theme.textFaint)
        }
        .accessibilityIdentifier("tests.output.\(suite.id)")
        .padding(.top, 8)
    }
}

/// One test, as a row.
private struct TestStepRow: View {
    let result: TestCaseResult
    let suiteID: String
    let onOpen: (TestArtifact) -> Void

    @State private var hovering = false

    private var tint: Color {
        switch result.outcome {
        case .passed: Theme.ok
        case .failed: Theme.danger
        case .skipped: Theme.textDim
        }
    }

    private var icon: String {
        switch result.outcome {
        case .passed: "circle-check"
        case .failed: "circle-x"
        case .skipped: "circle-minus"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TablerIcon(name: icon, size: 12, color: tint)
                .padding(.top, 1)
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
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !result.artifacts.isEmpty {
                    TestArtifactStrip(artifacts: result.artifacts, onOpen: onOpen)
                }
            }
            Spacer(minLength: 8)
            if let duration = result.duration {
                Text(TestStepFormat.duration(duration))
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
        if result.outcome == .failed { return Theme.dangerSurface }
        return hovering ? Theme.panelHover.opacity(0.6) : .clear
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The files one step or one run produced, as a row of small buttons.
private struct TestArtifactStrip: View {
    let artifacts: [TestArtifact]
    let onOpen: (TestArtifact) -> Void

    var body: some View {
        HStack(spacing: 6) {
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
                    HStack(spacing: 4) {
                        TablerIcon(name: iconName(artifact), size: 11, color: Theme.textDim)
                        Text(artifact.name)
                            .font(Theme.mono(.micro))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.statusSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
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

/// An artifact image, at the size it actually is.
private struct TestArtifactPreview: View {
    let artifact: TestArtifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Button("Done") { dismiss() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            if let image = NSImage(contentsOf: artifact.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 900, maxHeight: 600)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            } else {
                // The record outlives the file: a screenshot deleted between
                // runs should say so rather than show an empty frame.
                Text("The file is no longer at \(artifact.path)")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .padding(20)
            }
        }
        .padding(16)
        .background(Theme.panel)
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
