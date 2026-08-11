import Foundation

/// A file a test run left behind: a screenshot, a recording, a report.
///
/// Only what the suite itself wrote is listed. The path is absolute because it
/// is what gets opened in Finder or drawn into an image view; the name is what
/// the row shows, and it is the file's own name rather than anything invented.
struct TestArtifact: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case image
        case video
        case other

        /// Whether the app can draw it inline. Anything else is a row that
        /// opens in the user's own viewer, which is more honest than a broken
        /// thumbnail.
        var isPreviewable: Bool { self == .image }
    }

    var path: String
    var name: String
    var kind: Kind
    var modifiedAt: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// Finds the files a run produced and decides which step each belongs to.
///
/// Deliberately split in two: `collect` is pure over a listing so the matching
/// rules can be tested without a filesystem, and `scan` is the thin disk read
/// that feeds it. The matching itself is conservative — a file is attached to a
/// step only when their names actually agree. Guessing would put the wrong
/// screenshot next to a failure, which is worse than showing it unattached.
enum TestArtifactCollector {
    /// One file as the disk reported it.
    struct Entry: Equatable {
        var url: URL
        var modifiedAt: Date
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]

    /// A run of a thousand screenshots would be a scroll, not a report.
    static let limit = 200

    static func kind(for url: URL) -> TestArtifact.Kind {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return .other
    }

    /// The files written while the run was in flight, newest last.
    ///
    /// `startedAt` is backdated by a second: a suite that writes its first
    /// screenshot in the same instant the process starts would otherwise lose
    /// it to clock granularity, and the cost of the slack is at worst one stale
    /// file from the run before.
    static func collect(entries: [Entry], startedAt: Date, finishedAt: Date?) -> [TestArtifact] {
        let from = startedAt.addingTimeInterval(-1)
        let until = (finishedAt ?? Date()).addingTimeInterval(5)
        return entries
            .filter { $0.modifiedAt >= from && $0.modifiedAt <= until }
            .sorted { $0.modifiedAt < $1.modifiedAt }
            .prefix(limit)
            .map {
                TestArtifact(
                    path: $0.url.path,
                    name: $0.url.lastPathComponent,
                    kind: kind(for: $0.url),
                    modifiedAt: $0.modifiedAt
                )
            }
    }

    /// Hands each artifact to the step whose name it names, and returns what
    /// nobody claimed as the run's own.
    static func attach(
        _ artifacts: [TestArtifact], to cases: [TestCaseResult]
    ) -> (cases: [TestCaseResult], unattached: [TestArtifact]) {
        guard !artifacts.isEmpty else { return (cases, []) }
        var cases = cases
        var claimed = Set<String>()
        for (index, result) in cases.enumerated() {
            let key = normalise(result.name)
            guard key.count >= 4 else { continue }  // "test" alone matches everything
            let mine = artifacts.filter { artifact in
                let stem = normalise(artifact.url.deletingPathExtension().lastPathComponent)
                return stem.contains(key) || key.contains(stem)
            }
            guard !mine.isEmpty else { continue }
            cases[index].artifacts = mine
            claimed.formUnion(mine.map(\.id))
        }
        return (cases, artifacts.filter { !claimed.contains($0.id) })
    }

    /// Lowercased letters and digits only, so `smoke-01-anasayfa.png` and
    /// `smoke 01 anasayfa` are the same name written two ways.
    static func normalise(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Disk

    /// Lists a suite's artifact directory, recursively, skipping hidden files.
    ///
    /// Returns nothing rather than throwing: a suite whose artifact directory
    /// does not exist yet is the normal case on a first run, not an error worth
    /// a banner.
    static func scan(directory: URL) -> [Entry] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var entries: [Entry] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true, let date = values.contentModificationDate
            else { continue }
            entries.append(Entry(url: url, modifiedAt: date))
            if entries.count > limit * 4 { break }
        }
        return entries
    }

    /// Where a suite says it writes its artifacts, resolved against the project.
    ///
    /// A path that climbs out of the project is refused: the field is editable
    /// by agents, and the app should not be talked into listing `~/.ssh`.
    static func directory(
        for suite: TestSuiteConfiguration, projectRoot: URL
    ) -> URL? {
        guard let relative = suite.artifacts?.trimmingCharacters(in: .whitespaces),
              !relative.isEmpty else { return nil }
        let root = projectRoot.standardizedFileURL
        let candidate = (relative as NSString).isAbsolutePath
            ? URL(fileURLWithPath: relative).standardizedFileURL
            : root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
        else { return nil }
        return candidate
    }
}
