import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How far along a drop is, for the view that reports it.
enum SessionDropProgress: Equatable {
    case idle
    /// Copying. `done` of `total`, so several images say something while they
    /// land rather than the window simply going quiet.
    case working(done: Int, total: Int)
    case finished(String)
    case failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle: nil
        case .working(let done, let total):
            total > 1
                ? String(localized: "Attaching \(done + 1) of \(total)…")
                : String(localized: "Attaching…")
        case .finished(let text), .failed(let text): text
        }
    }
}

/// Writes dropped images into a session's own drop directory and types their
/// paths into its prompt.
enum SessionImageDropService {
    /// Everything a drop can carry that this accepts.
    ///
    /// `fileURL` covers Finder and most editors; `image` covers a drag out of
    /// Preview, a browser or a screenshot tool, where there is no file on disk
    /// yet and the data itself is what arrives.
    static let acceptedTypes: [UTType] = [.fileURL, .image]

    /// Handles a drop. Returns false when nothing in it was an image, so the
    /// caller's other drop handlers still get their turn.
    @MainActor
    @discardableResult
    static func handle(
        _ providers: [NSItemProvider],
        record: SessionRecord,
        project: Project,
        onProgress: @escaping (SessionDropProgress) -> Void = { _ in }
    ) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !candidates.isEmpty else { return false }

        let directory = URL(fileURLWithPath: record.workingDirectory(in: project))
            .appendingPathComponent(SessionImageDrop.directoryName(for: record.id))
        let sessionID = record.id
        let provider = record.provider

        onProgress(.working(done: 0, total: candidates.count))
        Task { @MainActor in
            var written: [String] = []
            for (index, item) in candidates.enumerated() {
                onProgress(.working(done: index, total: candidates.count))
                guard let payload = await payload(of: item) else { continue }
                // Off the main actor: an image is megabytes, and copying it
                // here is what made a drop feel like the window had stalled.
                let name = await Task.detached(priority: .userInitiated) {
                    write(payload, into: directory)
                }.value
                guard let name else { continue }
                written.append(
                    SessionImageDrop.relativePath(fileName: name, sessionID: sessionID)
                )
            }
            guard !written.isEmpty else {
                onProgress(.failed(String(localized: "Nothing in that drop could be attached.")))
                return
            }
            // Typed, not submitted: the drop is half a message, and the half
            // that says what the image is *for* is still being written.
            await TerminalRegistry.shared.typeText(
                SessionImageDrop.promptFragment(relativePaths: written),
                for: sessionID,
                provider: provider
            )
            onProgress(.finished(
                written.count == 1
                    ? String(localized: "Attached \(written[0]).")
                    : String(localized: "Attached \(written.count) images.")
            ))
        }
        return true
    }

    /// What one dropped item turned out to be.
    struct Payload: Sendable {
        var name: String
        /// The file it came from, when it came from one. Copying beats reading
        /// the whole thing into memory and writing it back out.
        var source: URL?
        var data: Data?
    }

    /// Writes one payload, returning the file name it landed under.
    ///
    /// `nonisolated` and taking only value types, so it can run off the main
    /// actor without dragging any UI state with it.
    nonisolated static func write(_ payload: Payload, into directory: URL) -> String? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let ignore = directory.deletingLastPathComponent()
                .appendingPathComponent(".gitignore")
            if !manager.fileExists(atPath: ignore.path) {
                try? Data(SessionImageDrop.ignoreContents.utf8).write(to: ignore)
            }
            let existing = Set(
                (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            )
            let name = SessionImageDrop.uniqueName(
                for: payload.name, at: Date(), existing: existing
            )
            let destination = directory.appendingPathComponent(name)
            if let source = payload.source {
                try manager.copyItem(at: source, to: destination)
            } else if let data = payload.data {
                try data.write(to: destination, options: .atomic)
            } else {
                return nil
            }
            return name
        } catch {
            return nil
        }
    }

    @MainActor
    private static func payload(of provider: NSItemProvider) async -> Payload? {
        // A file first: it has a name worth keeping, and copying it never
        // brings the image into memory at all.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadFileURL(provider),
           SessionImageDrop.isImage(fileName: url.lastPathComponent) {
            return Payload(name: url.lastPathComponent, source: url)
        }
        // No file: the image itself was dragged, so it is named after nothing
        // and has to be written out.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadImageData(provider) {
            return Payload(name: "image.png", data: data)
        }
        return nil
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { data, _ in
                guard let data else { return continuation.resume(returning: nil) }
                // Normalised to PNG: what arrives can be TIFF from the
                // pasteboard, and a `.png` name over TIFF bytes is a file no
                // agent can open.
                guard let image = NSBitmapImageRep(data: data),
                      let png = image.representation(using: .png, properties: [:])
                else { return continuation.resume(returning: data) }
                continuation.resume(returning: png)
            }
        }
    }

    // MARK: - Cleanup

    /// Removes a session's dropped images.
    ///
    /// Called when the session is closed. Without it the directory grows for
    /// the life of the project, holding screenshots for sessions that no longer
    /// exist — and nothing in a flat directory would even say which those were,
    /// which is why the images are filed per session in the first place.
    nonisolated static func removeDirectory(sessionID: UUID, workingDirectory: String) {
        let directory = URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(SessionImageDrop.directoryName(for: sessionID))
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes directories no live session owns.
    ///
    /// Not every close goes through the app: a session removed while Uncoil was
    /// not running, or on another machine, leaves its images behind. This is
    /// the sweep that catches those.
    nonisolated static func pruneOrphans(
        workingDirectory: String, liveSessionIDs: [UUID]
    ) {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(SessionImageDrop.directoryName)
        guard let present = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        for token in SessionImageDrop.orphanedTokens(
            present: present, liveSessionIDs: liveSessionIDs
        ) {
            try? manager.removeItem(at: root.appendingPathComponent(token))
        }
    }
}
