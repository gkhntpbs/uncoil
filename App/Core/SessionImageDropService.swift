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

/// Writes dropped files and images into a session's own drop directory and
/// hands them to the session as attachments.
///
/// How an attachment reaches the agent is the session's decision, not this
/// one's: a terminal gets the paths typed into its prompt, a structured Codex
/// session sends an image as an image.
enum SessionImageDropService {
    /// Everything a drop can carry that this accepts.
    ///
    /// `fileURL` covers Finder and most editors; `image` covers a drag out of
    /// Preview, a browser or a screenshot tool, where there is no file on disk
    /// yet and the data itself is what arrives.
    static let acceptedTypes: [UTType] = [.fileURL, .image]

    /// Handles a drop. Returns false when nothing in it was a file or an
    /// image, so the caller's other drop handlers still get their turn.
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
            var written: [AgentAttachment] = []
            for (index, item) in candidates.enumerated() {
                onProgress(.working(done: index, total: candidates.count))
                guard let payload = await payload(of: item) else { continue }
                // Off the main actor: an image is megabytes, and copying it
                // here is what made a drop feel like the window had stalled.
                let name = await Task.detached(priority: .userInitiated) {
                    write(payload, into: directory)
                }.value
                guard let name else { continue }
                written.append(attachment(named: name, in: directory, sessionID: sessionID))
            }
            guard !written.isEmpty else {
                onProgress(.failed(String(localized: "Nothing in that drop could be attached.")))
                return
            }
            // Attached, not submitted: the drop is half a message, and the half
            // that says what the file is *for* is still being written.
            await TerminalRegistry.shared.control(for: sessionID, provider: provider)
                .attach(written)
            onProgress(.finished(summary(written, verb: .attached)))
        }
        return true
    }

    /// The attachment for a file just written into the drop directory.
    nonisolated static func attachment(
        named name: String, in directory: URL, sessionID: UUID
    ) -> AgentAttachment {
        AgentAttachment(
            kind: SessionImageDrop.isImage(fileName: name) ? .image : .file,
            url: directory.appendingPathComponent(name),
            promptPath: SessionImageDrop.relativePath(fileName: name, sessionID: sessionID)
        )
    }

    enum Verb { case attached, pasted }

    /// What the drop overlay says once it is done.
    static func summary(_ attachments: [AgentAttachment], verb: Verb) -> String {
        if attachments.count == 1 {
            let path = attachments[0].promptPath
            return verb == .attached
                ? String(localized: "Attached \(path).")
                : String(localized: "Pasted \(path).")
        }
        let count = attachments.count
        if attachments.allSatisfy({ $0.kind == .image }) {
            return verb == .attached
                ? String(localized: "Attached \(count) images.")
                : String(localized: "Pasted \(count) images.")
        }
        return verb == .attached
            ? String(localized: "Attached \(count) files.")
            : String(localized: "Pasted \(count) files.")
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
           SessionImageDrop.isAttachable(url) {
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
        if provider.canLoadObject(ofClass: URL.self),
           let url = await withCheckedContinuation({ continuation in
               _ = provider.loadObject(ofClass: URL.self) { url, _ in
                   continuation.resume(returning: url)
               }
           }) { return url }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
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

    // MARK: - Pasting

    /// Handles ⌘V when the clipboard holds an image.
    ///
    /// Same destination and same prompt as a drop, deliberately: the two are
    /// the same act — handing the agent a picture — and having them land in
    /// different places would make the working directory harder to reason
    /// about than either of them is worth.
    ///
    /// Returns false when this paste is not ours, so ⌘V keeps meaning what it
    /// always did.
    @MainActor
    @discardableResult
    static func handlePaste(
        from pasteboard: NSPasteboard = .general,
        record: SessionRecord,
        project: Project,
        mode: ImagePasteMode,
        onProgress: @escaping (SessionDropProgress) -> Void = { _ in }
    ) -> Bool {
        guard let payloads = pastePayloads(from: pasteboard, mode: mode), !payloads.isEmpty
        else { return false }

        let directory = URL(fileURLWithPath: record.workingDirectory(in: project))
            .appendingPathComponent(SessionImageDrop.directoryName(for: record.id))
        let sessionID = record.id
        let provider = record.provider

        onProgress(.working(done: 0, total: payloads.count))
        Task { @MainActor in
            var written: [AgentAttachment] = []
            for (index, payload) in payloads.enumerated() {
                onProgress(.working(done: index, total: payloads.count))
                let name = await Task.detached(priority: .userInitiated) {
                    write(payload, into: directory)
                }.value
                guard let name else { continue }
                written.append(attachment(named: name, in: directory, sessionID: sessionID))
            }
            guard !written.isEmpty else {
                onProgress(.failed(String(localized: "That image could not be saved.")))
                return
            }
            await TerminalRegistry.shared.control(for: sessionID, provider: provider)
                .attach(written)
            onProgress(.finished(summary(written, verb: .pasted)))
        }
        return true
    }

    /// What is on the clipboard, if it is ours to take. nil means "not ours".
    static func pastePayloads(
        from pasteboard: NSPasteboard, mode: ImagePasteMode
    ) -> [Payload]? {
        guard mode == .attachFile else { return nil }

        // Files first, so a copied screenshot keeps the name it had.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty,
           ClipboardImagePaste.shouldIntercept(
               fileNames: urls.map(\.lastPathComponent), mode: mode
           ) {
            return urls.map { Payload(name: $0.lastPathComponent, source: $0) }
        }

        guard ClipboardImagePaste.shouldIntercept(types: pasteboard.types ?? [], mode: mode)
        else { return nil }
        // Normalised to PNG for the same reason a dropped image is: the
        // clipboard's own form is often TIFF, and a `.png` name over TIFF bytes
        // is a file no agent can open.
        guard let data = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff).flatMap(pngData(from:))
        else { return nil }
        return [Payload(name: "pasted.png", data: data)]
    }

    private static func pngData(from data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
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

/// Carries drop and paste progress to whatever is showing the session.
///
/// A drop is answered by the view and a paste by the app-wide key monitor,
/// which has no view state at all — but both are the same act to the user and
/// belong in the same place on screen. This is the one thing they share.
@MainActor
final class SessionDropReporter: ObservableObject {
    static let shared = SessionDropReporter()

    @Published private(set) var progress: [UUID: SessionDropProgress] = [:]

    func report(_ value: SessionDropProgress, for sessionID: UUID) {
        progress[sessionID] = value
    }

    func progress(for sessionID: UUID) -> SessionDropProgress {
        progress[sessionID] ?? .idle
    }

    func clear(_ sessionID: UUID) {
        progress[sessionID] = nil
    }
}
