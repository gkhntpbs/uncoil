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
    let facts: ProjectAreaFacts
    /// Called after something was set up, so the page reloads its facts.
    let onChanged: () -> Void

    @State private var busy: ProjectArea?
    @State private var message: String?

    private var offers: [ProjectArea] {
        // Tasks has its own card with the starter template and a dismissal, so
        // it is not repeated here.
        ProjectAreaAvailability.offers(facts).filter { $0 != .tasks }
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

    /// Runs the same detection the area's own screen runs.
    ///
    /// Nothing is invented: if the project has no dev server and no test setup,
    /// the answer is that nothing was found, and the tab stays away.
    private func setUp(_ offer: ProjectArea) {
        busy = offer
        message = nil
        let root = project.rootURL
        Task { @MainActor in
            let added: Int
            switch offer {
            case .run:
                let existing = RunConfigFile.load(projectRoot: root).configurations
                let found = await Task.detached(priority: .userInitiated) {
                    RunDetection.detect(fileSystem: DiskRunDetectionFileSystem(root: root))
                }.value
                let merged = RunDetection.merge(
                    existing: existing, suggestions: found, replacingDetected: false
                )
                try? RunConfigFile.save(merged, projectRoot: root)
                added = merged.count - existing.count
            case .tests:
                let existing = TestConfigFile.load(projectRoot: root).suites
                let found = await Task.detached(priority: .userInitiated) {
                    TestDetection.detect(fileSystem: DiskRunDetectionFileSystem(root: root))
                }.value
                let merged = TestConfigFile.merge(
                    existing: existing, suggestions: found, replacingDetected: false
                )
                try? TestConfigFile.save(merged, projectRoot: root)
                added = merged.count - existing.count
            case .overview, .tasks, .issues:
                added = 0
            }
            message = added > 0
                ? String(localized: "Found \(added). The tab is on the right.")
                : String(localized: "Nothing found. You can still write the configuration by hand, or ask an agent to.")
            busy = nil
            onChanged()
        }
    }
}
