import CryptoKit
import Foundation

/// Everything used to recognise the same task again after the file changed.
///
/// A fingerprint deliberately mixes strong and weak signals: the strong key
/// identifies a task that did not change at all, while the weaker inputs let a
/// task that was reworded or moved be re-matched — and, when that is not certain,
/// be flagged instead of guessed.
struct TaskFingerprint: Equatable, Codable {
    var filePath: String
    var headingPath: [String]
    /// Task text with case, punctuation and whitespace normalised away.
    var normalizedText: String
    /// Hash of the task's raw Markdown block.
    var rawHash: String
    /// Normalised text of the neighbouring tasks, for context matching.
    var previousText: String?
    var nextText: String?
    var orderUnderHeading: Int

    /// Same file, same heading chain, byte-identical block.
    var strongKey: String {
        Self.hash([filePath, headingPath.joined(separator: "\u{1}"), rawHash].joined(separator: "\u{2}"))
    }

    /// Same file, same heading chain, same position.
    var positionalKey: String {
        Self.hash([
            filePath,
            headingPath.joined(separator: "\u{1}"),
            String(orderUnderHeading),
        ].joined(separator: "\u{2}"))
    }

    /// Same file, same heading chain, same wording.
    var textKey: String {
        Self.hash([
            filePath,
            headingPath.joined(separator: "\u{1}"),
            normalizedText,
        ].joined(separator: "\u{2}"))
    }

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let words = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Dice coefficient over the normalised word sets.
    ///
    /// Dividing by the larger set alone punished a task that merely had a clause
    /// appended ("… yaz" → "… yaz ve test et") hard enough to look unrelated,
    /// while dividing by the smaller one would call any superset a match. Dice
    /// sits between the two, so a rewording still matches and unrelated text
    /// still scores zero.
    static func similarity(_ lhs: TaskFingerprint, _ rhs: TaskFingerprint) -> Double {
        let left = Set(lhs.normalizedText.split(separator: " ").map(String.init))
        let right = Set(rhs.normalizedText.split(separator: " ").map(String.init))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = left.intersection(right).count
        return 2 * Double(shared) / Double(left.count + right.count)
    }
}

/// Re-attaches Uncoil's own state (a session working a task) to tasks after the
/// file changed underneath.
///
/// Stages, strongest first: identical block, then same heading and position, then
/// wording similarity. Anything the stages cannot settle confidently is reported
/// as needing relinking rather than bound — attaching a session to the wrong task
/// is worse than asking.
enum TaskRelinker {
    /// Similarity at or above this is a candidate; below it, nothing.
    static let similarityFloor = 0.6
    /// A similarity match has to beat the runner-up by this much to be taken.
    static let ambiguityMargin = 0.15
    /// A positional match still needs the wording to be related. Without this
    /// one incidental shared word would be enough to hand a session a task that
    /// merely happens to sit in the same slot.
    static let positionalSimilarityFloor = 0.3

    enum Resolution: Equatable {
        /// Byte-identical block in the same place.
        case exact(newTaskID: String)
        /// Same heading and position, text moved on.
        case positional(newTaskID: String)
        /// Matched by wording, with the score that decided it.
        case similar(newTaskID: String, score: Double)
        /// Two or more candidates were too close to choose between.
        case ambiguous(candidates: [String])
        /// The task is gone.
        case missing

        var taskID: String? {
            switch self {
            case .exact(let id), .positional(let id): id
            case .similar(let id, _): id
            case .ambiguous, .missing: nil
            }
        }

        /// Only a resolved match may be bound automatically.
        var isAutomatic: Bool { taskID != nil }

        var needsRelinking: Bool {
            switch self {
            case .ambiguous, .missing: true
            case .exact, .positional, .similar: false
            }
        }

        var label: String {
            switch self {
            case .exact: String(localized: "Same task")
            case .positional: String(localized: "Matched by position")
            case .similar(_, let score): String(localized: "Matched by similarity (\(Int(score * 100))%)")
            case .ambiguous(let candidates): String(localized: "Ambiguous: \(candidates.count) candidates")
            case .missing: String(localized: "Not found")
            }
        }
    }

    /// Resolves one previously-known fingerprint against the current tasks.
    static func resolve(
        _ old: TaskFingerprint,
        in tasks: [ProjectTask]
    ) -> Resolution {
        let sameFile = tasks.filter { $0.fingerprint.filePath == old.filePath }
        guard !sameFile.isEmpty else { return .missing }

        if let exact = sameFile.first(where: { $0.fingerprint.strongKey == old.strongKey }) {
            return .exact(newTaskID: exact.id)
        }

        // Position is only trustworthy when it identifies exactly one task.
        let positional = sameFile.filter { $0.fingerprint.positionalKey == old.positionalKey }
        if positional.count == 1,
           TaskFingerprint.similarity(old, positional[0].fingerprint) >= positionalSimilarityFloor {
            return .positional(newTaskID: positional[0].id)
        }

        let textual = sameFile.filter { $0.fingerprint.textKey == old.textKey }
        if textual.count == 1 {
            return .positional(newTaskID: textual[0].id)
        }
        if textual.count > 1 {
            return .ambiguous(candidates: textual.map(\.id).sorted())
        }

        let scored = sameFile
            .map { (task: $0, score: TaskFingerprint.similarity(old, $0.fingerprint)) }
            .filter { $0.score >= similarityFloor }
            .sorted { $0.score > $1.score }
        guard let best = scored.first else { return .missing }
        if scored.count > 1, best.score - scored[1].score < ambiguityMargin {
            return .ambiguous(
                candidates: scored
                    .filter { best.score - $0.score < ambiguityMargin }
                    .map(\.task.id)
                    .sorted()
            )
        }
        return .similar(newTaskID: best.task.id, score: best.score)
    }

    /// Resolves many at once, refusing to give two old tasks the same new task —
    /// that is exactly how a session ends up on the wrong work.
    static func resolveAll(
        _ old: [String: TaskFingerprint],
        in tasks: [ProjectTask]
    ) -> [String: Resolution] {
        var result: [String: Resolution] = [:]
        var claimed: [String: String] = [:]

        // Exact matches first so a rewording never steals a task that an
        // unchanged entry already owns.
        let ordered = old.sorted { $0.key < $1.key }
        for (key, fingerprint) in ordered {
            let resolution = resolve(fingerprint, in: tasks)
            guard case .exact(let newID) = resolution else { continue }
            result[key] = resolution
            claimed[newID] = key
        }
        for (key, fingerprint) in ordered where result[key] == nil {
            let resolution = resolve(fingerprint, in: tasks)
            if let newID = resolution.taskID, let owner = claimed[newID], owner != key {
                result[key] = .ambiguous(candidates: [newID])
                continue
            }
            if let newID = resolution.taskID { claimed[newID] = key }
            result[key] = resolution
        }
        return result
    }
}
