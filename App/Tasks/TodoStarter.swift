import Foundation

/// Creating a project's first `TODO.md`, and remembering who has been told it
/// exists.
///
/// Both halves were previously inside the onboarding step, which meant only a
/// user who went through first-run setup ever learned that Uncoil hands out
/// work from a plain Markdown file. Every other project silently offered no
/// Tasks tab and no explanation for why.
enum TodoStarter {
    static let fileName = "TODO.md"

    /// The starter file. Deliberately three lines of real shape rather than an
    /// empty heading: the format is the point of the offer, and an empty file
    /// teaches nothing.
    static let template = """
    # TODO

    ## Next
    - [ ] Describe the first task in one line
    - [ ] And the second

    ## Later
    - [ ] Something that can wait
    """

    enum CreateError: Error, Equatable {
        /// A file is already there. The shortcut saves typing; it never touches
        /// a file the user owns.
        case alreadyExists
        case write(String)
    }

    /// Writes the starter file into `projectPath` and returns its path.
    static func create(in projectPath: String) -> Result<String, CreateError> {
        let url = URL(fileURLWithPath: projectPath).appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.alreadyExists)
        }
        do {
            try Data(template.utf8).write(to: url, options: .withoutOverwriting)
            return .success(url.path)
        } catch {
            return .failure(.write(error.localizedDescription))
        }
    }
}

/// Which projects have already been offered a `TODO.md` and said no.
///
/// Per project, and permanent: a hint that comes back after it was dismissed is
/// not a hint, it is nagging. Reopening the offer is what creating the file by
/// hand does — the card is gone the moment a task source exists.
enum TodoHintDismissal {
    private static let key = "tasks.todoHintDismissedProjects"

    static func isDismissed(_ projectID: UUID, defaults: UserDefaults = .standard) -> Bool {
        dismissed(defaults).contains(projectID.uuidString)
    }

    static func dismiss(_ projectID: UUID, defaults: UserDefaults = .standard) {
        var ids = dismissed(defaults)
        ids.insert(projectID.uuidString)
        defaults.set(Array(ids).sorted(), forKey: key)
    }

    static func reset(_ projectID: UUID, defaults: UserDefaults = .standard) {
        var ids = dismissed(defaults)
        ids.remove(projectID.uuidString)
        defaults.set(Array(ids).sorted(), forKey: key)
    }

    private static func dismissed(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}
