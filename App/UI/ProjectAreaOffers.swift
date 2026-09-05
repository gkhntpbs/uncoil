import SwiftUI

/// What the General page offers for the areas this project does not have yet.
///
/// Tabs are only shown for areas with something in them, which is right — four
/// tabs onto empty pages is worse than none — but it leaves a project with no
/// way to discover the features it could turn on. This is that way, and it
/// follows the TODO.md offer that already worked: say what the feature is, and
/// give it one button.
struct ProjectAreaOffers: View {
    let project: Project
    let capabilities: ProjectCapabilities
    /// Called after something was set up, so the page looks again.
    let onChanged: () -> Void

    @State private var busy: ProjectArea?
    @State private var message: String?

    private var offers: [ProjectArea] {
        // Tasks has its own card with the starter template and a dismissal, so
        // it is not repeated here.
        ProjectAreaAvailability.offers(capabilities).filter { $0 != .tasks }
    }

    var body: some View {
        if !offers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeading(title: String(localized: "Set up"), count: offers.count)
                VStack(alignment: .leading, spacing: 10) {
                    if let message {
                        Text(message)
                            .font(Theme.mono(.small))
                            .foregroundStyle(Theme.textDim)
                    }
                    ForEach(offers) { offer in
                        row(offer)
                    }
                }
                .padding(14)
            }
            .panel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dashboard.offers")
        }
    }

    private func row(_ offer: ProjectArea) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TablerIcon(name: offer.iconName, size: 13, color: Theme.textFaint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(offer.offerTitle)
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.text)
                Text(offer.offerDetail)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if busy == offer {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else if offer.offerIsActionable {
                Button { setUp(offer) } label: { Text("Look") }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("dashboard.offer.\(offer.rawValue)")
            }
        }
    }

    /// The same detection the area's own screen runs, because it is the same
    /// detection: `ProjectSetup` is the one entry point, so what "Look" finds
    /// here and what the tab's own button finds cannot disagree.
    private func setUp(_ offer: ProjectArea) {
        guard let capability = ProjectAreaAvailability.capability(for: offer) else { return }
        busy = offer
        message = nil
        Task { @MainActor in
            message = await ProjectSetup.look(for: capability, in: project).summary
            busy = nil
            onChanged()
        }
    }
}
