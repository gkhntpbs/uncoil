import Foundation
import UniformTypeIdentifiers

/// Taking an image dropped on a session and making it something the agent can
/// actually open.
///
/// The constraint that shapes all of this: a CLI agent reads files from disk,
/// through its own sandbox. Codex is confined to its workspace, and Claude Code
/// asks before reading outside the working directory. So an image dropped on a
/// session cannot live in Application Support beside the session's other
/// artifacts — it has to land inside the working directory, and be referred to
/// by a path relative to it, which is the one form no agent has to ask about.
enum SessionImageDrop {
    /// Where dropped images go, relative to the session's working directory.
    ///
    /// Under `.uncoil/`, which the project already has for `run.json` and
    /// `tests.json` — but in a subdirectory of its own, because those two are
    /// meant to be committed and these are not.
    static let directoryName = ".uncoil/dropped"

    /// One directory per session, inside it.
    ///
    /// A flat directory would grow without limit, and worse, nothing in it
    /// would say which session an image belonged to — so closing a session
    /// could not take its images with it. Ownership has to be in the path.
    ///
    /// Eight hex characters rather than the whole id: the path is read by a
    /// person in their own prompt, and thirty-six characters of UUID there is
    /// noise. Collisions are handled where they matter, by never deleting a
    /// directory whose token still belongs to a live session.
    static func token(for sessionID: UUID) -> String {
        String(sessionID.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
            .lowercased()
    }

    static func directoryName(for sessionID: UUID) -> String {
        "\(directoryName)/\(token(for: sessionID))"
    }

    /// Written into the directory when it is created.
    ///
    /// A self-contained ignore rather than an edit to the project's own
    /// `.gitignore`: that file belongs to the user, is often reviewed line by
    /// line, and Uncoil adding to it silently is a change to their repository
    /// they did not ask for. A `.gitignore` inside the directory ignores only
    /// the directory, and takes nothing with it if it is deleted.
    static let ignoreContents = """
    # Images dropped onto an Uncoil session. Transient; not part of the project.
    *
    """

    /// File extensions treated as images.
    ///
    /// Matched by extension rather than by asking the file: the drop has to be
    /// answered while the pointer is still down, and the name is what is
    /// already in hand.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
    ]

    static func isImage(fileName: String) -> Bool {
        imageExtensions.contains(
            (fileName as NSString).pathExtension.lowercased()
        )
    }

    /// A name that will not collide with what is already there.
    ///
    /// Two screenshots dropped in a row are both called `Screenshot.png`, and
    /// the second silently replacing the first would lose the image the user
    /// just handed over. The stamp goes in front so the directory reads in the
    /// order things were dropped.
    static func uniqueName(
        for original: String, at date: Date, existing: Set<String>
    ) -> String {
        let base = sanitised(original)
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        let stamp = stampFormatter.string(from: date)
        var candidate = ext.isEmpty ? "\(stamp)-\(stem)" : "\(stamp)-\(stem).\(ext)"
        var counter = 2
        while existing.contains(candidate) {
            candidate = ext.isEmpty
                ? "\(stamp)-\(stem)-\(counter)"
                : "\(stamp)-\(stem)-\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// Strips anything that would make the name mean something other than a
    /// name: a separator that would place the file elsewhere, a parent
    /// reference, or leading dots that would hide it.
    ///
    /// The name comes from whatever was dragged, which is to say from outside.
    /// It is used to build a path, so it has to be a name and nothing else.
    static func sanitised(_ name: String) -> String {
        let separatorless = String(name.map { character in
            character == "/" || character == ":" || character == "\\" ? "-" : character
        })
        // After the separators are gone a `..` cannot climb anywhere, but it
        // reads as though it might; replacing it keeps the name honest and the
        // invariant one line long.
        var collapsed = separatorless
        while collapsed.contains("..") {
            collapsed = collapsed.replacingOccurrences(of: "..", with: "-")
        }
        let cleaned = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return cleaned.isEmpty ? "image" : cleaned
    }

    /// What goes into the prompt for the images just dropped.
    ///
    /// Paths only, and relative ones. No wording is put in the user's mouth:
    /// the drop is half a message, and what it is *about* is the half they are
    /// still typing. A trailing space so the cursor lands ready for it.
    static func promptFragment(relativePaths: [String]) -> String {
        guard !relativePaths.isEmpty else { return "" }
        return relativePaths.map(quoted).joined(separator: " ") + " "
    }

    /// A path with a space in it is two arguments to the shell — and a prompt
    /// is read by one.
    static func quoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }

    /// The relative path an agent is given for a file in the drop directory.
    static func relativePath(fileName: String, sessionID: UUID) -> String {
        "\(directoryName(for: sessionID))/\(fileName)"
    }

    /// Session directories with no live session behind them.
    ///
    /// The per-session directory is removed when its session is closed, but not
    /// every close goes through the app: a session removed while Uncoil was not
    /// running, or on another machine, leaves its images behind. This is the
    /// sweep that catches those, and it is deliberately conservative — a
    /// directory is only orphaned when its token matches no session at all.
    static func orphanedTokens(
        present: [String], liveSessionIDs: [UUID]
    ) -> [String] {
        let live = Set(liveSessionIDs.map(token(for:)))
        return present.filter { !live.contains($0) && $0 != ".gitignore" }
    }
}
