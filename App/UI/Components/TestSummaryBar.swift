import SwiftUI

/// The one line a run is judged by: how far it got, how it went, and the way
/// into the detail.
///
/// The same bar serves a run in flight and a finished one, which is the point —
/// the numbers change, the shape does not, so nothing jumps when the suite
/// ends. When a selection binding is passed, the three tallies double as the
/// filter for the list underneath: a count that can be clicked is worth more
/// than a count beside a row of buttons that say the same words.
struct TestSummaryBar<Trailing: View>: View {
    /// Tests that actually ran. Skipped ones are part of the total, not of it.
    let done: Int
    /// Zero when it is not known.
    let total: Int
    /// Set when the total is an estimate — the last run's — rather than this
    /// run's own count or a plan the runner announced.
    var totalIsEstimate = false
    let summary: TestRunSummary
    /// Nil draws the tallies as labels rather than as filters.
    var selection: Binding<TestStepList.Filter?>?
    /// How many rows each filter would actually produce.
    var counts: ((TestStepList.Filter) -> Int)?
    var isLive = false
    /// Nil hides the chevron — a bar with nothing to open.
    var isExpanded: Binding<Bool>?
    var identifierPrefix = "summary"
    @ViewBuilder var trailing: () -> Trailing

    private var active: TestStepList.Filter {
        selection?.wrappedValue ?? TestStepList.defaultFilter(for: summary)
    }

    var body: some View {
        HStack(spacing: 6) {
            ProgressChip(
                done: done,
                total: total,
                isLive: isLive,
                isSelected: selection != nil && active == .all,
                help: totalIsEstimate
                    ? String(localized: "Out of \(total), which is what the last run reported")
                    : nil,
                action: selection.map { binding in
                    {
                        binding.wrappedValue = .all
                        expand()
                    }
                },
                identifier: "\(identifierPrefix).all"
            )
            tally(.passed, count: summary.passed, tint: Theme.ok, label: "passed")
            tally(.failed, count: summary.failed, tint: Theme.danger, label: "failed")
            tally(.skipped, count: summary.skipped, tint: Theme.textDim, label: "skipped")
            Spacer(minLength: Theme.Space.tight)
            trailing()
            if let isExpanded {
                Button {
                    withAnimation(Theme.Motion.quick) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    TablerIcon(
                        name: isExpanded.wrappedValue ? "chevron-up" : "chevron-down",
                        size: 13, color: Theme.textDim
                    )
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    isExpanded.wrappedValue
                        ? String(localized: "Hide the steps") : String(localized: "Show the steps")
                )
                .accessibilityIdentifier("\(identifierPrefix).expand")
            }
        }
        // No inset of its own: the chips line up with the left edge of the
        // rows below, and the meta on the right with theirs.
        .frame(minHeight: 24)
        .animation(Theme.Motion.quick, value: summary)
    }

    /// Choosing what to look at is asking to see it: picking a filter on a
    /// collapsed card used to change a list nobody could see.
    private func expand() {
        guard let isExpanded, !isExpanded.wrappedValue else { return }
        withAnimation(Theme.Motion.quick) { isExpanded.wrappedValue = true }
    }

    @ViewBuilder
    private func tally(
        _ filter: TestStepList.Filter, count: Int, tint: Color, label: String
    ) -> some View {
        // Counted from the rows when the list is filterable, so a tally never
        // promises rows the filter cannot produce; from the summary otherwise,
        // where the runner's own totals are all there is.
        let value = counts?(filter) ?? count
        // A bucket that never had anything in it is not drawn while a run is in
        // flight: three greyed zeroes is what the bar looks like at the start
        // of every run, and it says nothing.
        if !isLive || value > 0 {
            CountChip(
                label: label,
                count: value,
                tint: tint,
                isSelected: selection != nil && active == filter,
                action: selection.map { binding in
                    {
                        binding.wrappedValue = active == filter ? .all : filter
                        expand()
                    }
                },
                identifier: "\(identifierPrefix).\(filter.rawValue)"
            )
        }
    }
}

extension TestSummaryBar where Trailing == EmptyView {
    init(
        done: Int,
        total: Int,
        totalIsEstimate: Bool = false,
        summary: TestRunSummary,
        selection: Binding<TestStepList.Filter?>? = nil,
        counts: ((TestStepList.Filter) -> Int)? = nil,
        isLive: Bool = false,
        isExpanded: Binding<Bool>? = nil,
        identifierPrefix: String = "summary"
    ) {
        self.init(
            done: done, total: total, totalIsEstimate: totalIsEstimate,
            summary: summary, selection: selection, counts: counts,
            isLive: isLive, isExpanded: isExpanded, identifierPrefix: identifierPrefix,
            trailing: { EmptyView() }
        )
    }
}
