import Foundation

/// Turning a capability on for a project — once, for every surface that offers
/// it.
///
/// "Look for this project's run setup" was written three times (the General
/// page's offer, the Run tab's Detect button, the Tests tab's empty state) and
/// each copy loaded, detected, merged and saved for itself. They had drifted in
/// the way copies do: one reported what it found and one silently did nothing,
/// one surfaced a write failure and one swallowed it, and the same action was
/// called "Look", "Detect" and "Look for tests" depending on where you clicked.
///
/// Nothing here invents configuration. If the project has no dev server and no
/// test setup, the answer is that nothing was found, and the tab stays away —
/// which is the whole reason the offer is honest enough to show.
enum ProjectSetup {
    struct Outcome: Equatable {
        /// How many configurations this run added. Zero with no error means
        /// the project genuinely has nothing of this kind to find.
        var added: Int
        /// What could not be written, if anything.
        var error: String?

        /// What to tell the user, in the same words wherever they clicked.
        var summary: String {
            if let error { return error }
            guard added > 0 else {
                return String(localized: "Nothing found. You can still write the configuration by hand, or ask an agent to.")
            }
            return String(localized: "Found \(added).")
        }
    }

    /// Whether Uncoil can act on this capability at all, or only explain it.
    ///
    /// Nothing in the app can give a folder a GitHub remote, and a capability
    /// that cannot be acted on must not be offered with a button that does
    /// nothing when pressed.
    static func isActionable(_ capability: ProjectCapability) -> Bool {
        switch capability {
        case .run, .tests, .tasks: true
        case .git, .gitHubRepository: false
        }
    }

    /// Looks for what the project already has, and writes down what it finds.
    ///
    /// Merging rather than replacing: a configuration the user wrote by hand is
    /// theirs, and a second look must not overwrite it with a guess.
    static func look(for capability: ProjectCapability, in project: Project) async -> Outcome {
        let root = project.rootURL
        switch capability {
        case .run:
            let existing = RunConfigFile.load(projectRoot: root).configurations
            let found = await Task.detached(priority: .userInitiated) {
                RunDetection.detect(fileSystem: DiskRunDetectionFileSystem(root: root))
            }.value
            let merged = RunDetection.merge(
                existing: existing, suggestions: found, replacingDetected: false
            )
            do {
                try RunConfigFile.save(merged, projectRoot: root)
            } catch {
                return Outcome(added: 0, error: String(localized: "Could not write \(RunConfigFile.relativePath): \(error.localizedDescription)"))
            }
            return Outcome(added: merged.count - existing.count)
        case .tests:
            let existing = TestConfigFile.load(projectRoot: root).suites
            let found = await Task.detached(priority: .userInitiated) {
                TestDetection.detect(fileSystem: DiskRunDetectionFileSystem(root: root))
            }.value
            let merged = TestConfigFile.merge(
                existing: existing, suggestions: found, replacingDetected: false
            )
            do {
                try TestConfigFile.save(merged, projectRoot: root)
            } catch {
                return Outcome(added: 0, error: String(localized: "Could not write \(TestConfigFile.relativePath): \(error.localizedDescription)"))
            }
            return Outcome(added: merged.count - existing.count)
        case .tasks:
            // Nothing to detect: a task list is written, not found. An existing
            // file counts as success — the point was to have one.
            switch TodoStarter.create(in: project.rootPath) {
            case .success: return Outcome(added: 1)
            case .failure(.alreadyExists): return Outcome(added: 0)
            case .failure(.write(let message)): return Outcome(added: 0, error: message)
            }
        case .git, .gitHubRepository:
            return Outcome(added: 0)
        }
    }
}
