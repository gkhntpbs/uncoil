import Foundation

enum BlueprintError: LocalizedError, Equatable {
    case emptyName
    case invalidName(String)
    case promptTooLong(Int)
    case notFound(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "A blueprint needs a name."
        case .invalidName(let name):
            "“\(name)” does not turn into a usable file name; it needs a letter or a digit."
        case .promptTooLong(let limit):
            "The prompt is longer than \(limit) characters."
        case .notFound(let id):
            "No blueprint called \(id)."
        case .write(let detail):
            "The blueprint could not be written: \(detail)."
        }
    }
}

/// The blueprints on this machine, one markdown file each.
///
/// A folder of files rather than a blob inside `settings.json`, because these
/// are meant to be read, edited, copied to another Mac and sent to someone
/// else. Export is copying the file out and import is copying one in; there is
/// no format to convert and nothing for a converter to lose.
@MainActor
final class BlueprintStore: ObservableObject {
    /// Prompts are fed into a PTY later, so the cap is the same order as the
    /// control plane's `initial_prompt` limit — long enough for a page of
    /// instructions, short enough that nothing can paste a book into a session.
    static let promptLimit = 8000

    static let shared = BlueprintStore()

    @Published private(set) var blueprints: [Blueprint] = []

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".uncoil/blueprints", isDirectory: true)
        reload()
    }

    // MARK: - Reading

    func reload() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            blueprints = []
            return
        }
        blueprints = entries
            .filter { $0.pathExtension == "md" }
            // A file that does not parse is skipped rather than fatal: a stray
            // note dropped into the folder must not empty the list.
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Blueprint.parse(text, id: url.deletingPathExtension().lastPathComponent)
            }
            // Sorted by name, then by id. Two blueprints may share a name —
            // duplicating one is how a variant gets made — and a comparison
            // that ties there would leave their order to whatever the file
            // system listed first, so the row of cards would reshuffle itself
            // between launches.
            .sorted {
                let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
                return byName == .orderedSame ? $0.id < $1.id : byName == .orderedAscending
            }
    }

    func blueprint(id: String) -> Blueprint? {
        blueprints.first { $0.id == id }
    }

    // MARK: - Writing

    /// Turns a display name into a file name, and into the id agents use.
    static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    /// A slug nothing else is using, so saving a second "Full stack" does not
    /// silently overwrite the first.
    func availableID(for name: String, excluding existing: String? = nil) -> String {
        let base = Self.slug(name)
        guard !base.isEmpty else { return base }
        var candidate = base
        var suffix = 2
        while candidate != existing, blueprints.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Writes a blueprint and returns it as stored.
    ///
    /// `writtenByAgent` is not a label, it is a restraint. A blueprint is text
    /// that later gets handed to an agent, so one an agent produced is stored
    /// as a draft: it never starts by itself, and it is marked until a person
    /// has opened it. Otherwise a session could leave instructions behind for
    /// a session that has not started yet.
    @discardableResult
    func save(_ incoming: Blueprint, writtenByAgent: Bool = false) throws -> Blueprint {
        let name = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BlueprintError.emptyName }
        guard !Self.slug(name).isEmpty else { throw BlueprintError.invalidName(name) }
        guard incoming.prompt.count <= Self.promptLimit else {
            throw BlueprintError.promptTooLong(Self.promptLimit)
        }

        var stored = incoming
        stored.name = name
        if writtenByAgent {
            stored.needsReview = true
            stored.startsImmediately = false
        }

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Data(stored.markdown().utf8).write(to: url(for: stored.id), options: .atomic)
        } catch {
            throw BlueprintError.write(error.localizedDescription)
        }
        reload()
        return blueprint(id: stored.id) ?? stored
    }

    func delete(id: String) throws {
        guard blueprint(id: id) != nil else { throw BlueprintError.notFound(id) }
        do {
            try FileManager.default.removeItem(at: url(for: id))
        } catch {
            throw BlueprintError.write(error.localizedDescription)
        }
        reload()
    }

    /// Clears the draft mark once someone has actually looked at it.
    func markReviewed(id: String) {
        guard var reviewed = blueprint(id: id), reviewed.needsReview else { return }
        reviewed.needsReview = false
        try? save(reviewed)
    }

    // MARK: - Import / export

    func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).md")
    }

    /// Reads a file the user picked. The id comes from its contents' name
    /// rather than the file name, so a blueprint someone renamed on the way
    /// over still lands under a slug that matches what it calls itself.
    @discardableResult
    func importBlueprint(from source: URL) throws -> Blueprint {
        guard let text = try? String(contentsOf: source, encoding: .utf8),
              let parsed = Blueprint.parse(
                  text, id: source.deletingPathExtension().lastPathComponent
              )
        else { throw BlueprintError.invalidName(source.lastPathComponent) }
        let incoming = parsed
        // Imported from elsewhere, so the same restraint applies as for one an
        // agent wrote: nothing someone else authored starts on its own.
        return try save(
            Blueprint(
                id: availableID(for: incoming.name),
                name: incoming.name,
                iconName: incoming.iconName,
                colorHex: incoming.colorHex,
                prompt: incoming.prompt,
                startsImmediately: incoming.startsImmediately
            ),
            writtenByAgent: true
        )
    }

    func export(id: String, to destination: URL) throws {
        guard let existing = blueprint(id: id) else { throw BlueprintError.notFound(id) }
        do {
            try Data(existing.markdown().utf8).write(to: destination, options: .atomic)
        } catch {
            throw BlueprintError.write(error.localizedDescription)
        }
    }
}
