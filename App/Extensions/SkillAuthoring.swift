import Foundation

/// Creating a skill from inside Uncoil, or taking one in from a folder.
///
/// Both paths end in the same place: an immutable revision in Uncoil's store
/// with the active symlink pointing at it. Neither writes into an agent's
/// directory on its own — assignment does that, and only for the agents the user
/// picked.
enum SkillAuthoringError: LocalizedError, Equatable {
    case emptyName
    case invalidName(String)
    case alreadyExists(String)
    case notASkillFolder(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "The skill's name cannot be empty."
        case .invalidName(let name):
            "“\(name)” does not turn into a usable folder name; it needs a letter or a digit."
        case .alreadyExists(let name):
            "A skill named \(name) already exists."
        case .notASkillFolder(let path):
            "\(path) is not a skill folder: there is no SKILL.md inside."
        }
    }
}

@MainActor
struct SkillAuthoringService {
    struct Draft: Equatable {
        var name: String = ""
        var summary: String = ""
        var body: String = ""
    }

    var layout: ExtensionStoreLayout
    var store: SkillStore

    init(layout: ExtensionStoreLayout, store: SkillStore? = nil) {
        self.layout = layout
        self.store = store ?? SkillStore(layout: layout)
    }

    /// Folder-safe name: what the agents will actually see on disk.
    static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed
    }

    /// The SKILL.md an agent reads: the description is the part that decides
    /// whether the skill is ever triggered, so it is written into the front
    /// matter rather than buried in the body.
    static func markdown(_ draft: Draft) -> String {
        let slug = slug(draft.name)
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ---
        name: \(slug)
        description: \(summary)
        ---

        # \(draft.name.trimmingCharacters(in: .whitespacesAndNewlines))

        \(body)

        """
    }

    /// Writes a new skill into the store and returns the package to record.
    func create(_ draft: Draft, now: Date = .now) throws -> ExtensionPackage {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkillAuthoringError.emptyName }
        let name = Self.slug(trimmed)
        guard !name.isEmpty else { throw SkillAuthoringError.invalidName(trimmed) }
        guard !FileManager.default.fileExists(atPath: layout.activeSkill(name).path) else {
            throw SkillAuthoringError.alreadyExists(name)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-new-skill-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
        }
        try Data(Self.markdown(draft).utf8).write(
            to: staging.appendingPathComponent("SKILL.md"), options: .atomic
        )
        return try install(from: staging, name: name, summary: draft.summary, now: now)
    }

    /// Copies an existing skill folder in. The folder the user picked is left
    /// exactly as it is: Uncoil works on its own copy.
    func importFolder(at url: URL, now: Date = .now) throws -> ExtensionPackage {
        guard SkillStore.isSkillDirectory(url) else {
            throw SkillAuthoringError.notASkillFolder(url.path)
        }
        let name = Self.slug(url.lastPathComponent)
        guard !name.isEmpty else {
            throw SkillAuthoringError.invalidName(url.lastPathComponent)
        }
        guard !FileManager.default.fileExists(atPath: layout.activeSkill(name).path) else {
            throw SkillAuthoringError.alreadyExists(name)
        }
        return try install(from: url, name: name, summary: nil, now: now)
    }

    private func install(
        from source: URL,
        name: String,
        summary: String?,
        now: Date
    ) throws -> ExtensionPackage {
        let revisionID = "created-\(name)-\(Int(now.timeIntervalSince1970))"
        let revision = try store.install(
            from: source, name: name, revisionID: revisionID, now: now
        )
        // The shared location every agent can read; a per-agent link is only made
        // when the user assigns the skill to that agent.
        _ = try? store.linkCanonical(name: name)
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtensionPackage(
            id: "created:\(name)",
            kind: .skill,
            name: name,
            summary: trimmedSummary?.isEmpty == false ? trimmedSummary : String(localized: "Created inside Uncoil"),
            source: .local(path: revision.path),
            state: .active,
            activeRevision: revision,
            lastFetchedAt: now
        )
    }

    /// Links a skill into an agent's own directory, which is what makes an
    /// assignment visible to that agent.
    @discardableResult
    func link(name: String, into installation: AgentInstallation) -> Bool {
        guard let directory = installation.skillsDirectory else { return false }
        return (try? store.link(
            name: name, intoAgentDirectory: URL(fileURLWithPath: directory)
        )) != nil
    }
}
