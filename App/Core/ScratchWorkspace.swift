import Foundation

/// The folder one-off sessions run in.
///
/// A session needs a working directory — an agent with nowhere to stand cannot
/// read a file, write one, or run anything — so "a session without a project"
/// still needs somewhere to be. Rather than inventing a second kind of session
/// that every part of the app would have to know about, one-off sessions belong
/// to a project like any other. It is just a project Uncoil owns.
///
/// That is what keeps this small: terminals, hooks, the control plane, the
/// runtime daemon and the sidebar all go on working unchanged.
enum ScratchWorkspace {
    /// Shown in the sidebar and used as the project's name.
    static let name = String(localized: "Scratch")

    /// Under Uncoil's own data directory rather than the user's home.
    ///
    /// A folder Uncoil creates unasked does not belong in someone's home, and
    /// this one is for errands — "what does this command do", "reformat this
    /// snippet" — not for work anyone will look for later. What is worth
    /// keeping gets moved out, and Show in Finder is one click away.
    static func directory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("Scratch", isDirectory: true)
    }

    /// Creates the folder if it is not there, and returns it.
    @discardableResult
    static func ensureDirectory(dataDirectory: URL) -> URL {
        let directory = directory(dataDirectory: dataDirectory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        // A note for whoever finds the folder without Uncoil in front of them.
        let readme = directory.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try? Data(readmeContents.utf8).write(to: readme)
        }
        return directory
    }

    static let readmeContents = """
    # Scratch

    Uncoil runs one-off agent sessions here — the small jobs that do not belong
    to any project. Anything worth keeping should be moved somewhere it will be
    looked for; nothing here is backed up, versioned, or otherwise looked after.
    """

    /// Titles a one-off session by when it was opened.
    ///
    /// A session with no project has no folder name to be called after, and
    /// "new session" repeated down the sidebar tells nobody anything. The time
    /// is what actually distinguishes one errand from the next.
    static func sessionTitle(for provider: AgentProvider, at date: Date) -> String {
        "\(provider.displayName) · \(timeFormatter.string(from: date))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// Where a project sorts in the sidebar.
///
/// Scratch always last, whatever else is true of it: pinning and manual order
/// are about the projects someone chose to open, and a folder Uncoil owns
/// competing with those for the top of the list would be the app putting its
/// own housekeeping above the user's work.
enum ProjectSortRank {
    static func rank(isScratch: Bool, isPinned: Bool) -> Int {
        if isScratch { return 2 }
        return isPinned ? 0 : 1
    }
}
