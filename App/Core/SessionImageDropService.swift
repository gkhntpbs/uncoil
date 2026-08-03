import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Writes dropped images into a session's working directory and types their
/// paths into its prompt.
@MainActor
enum SessionImageDropService {
    /// Everything a drop can carry that this accepts.
    ///
    /// `fileURL` covers Finder and most editors; `image` covers a drag out of
    /// Preview, a browser or a screenshot tool, where there is no file on disk
    /// yet and the data itself is what arrives.
    static let acceptedTypes: [UTType] = [.fileURL, .image]

    /// Handles a drop. Returns false when nothing in it was an image, so the
    /// caller's other drop handlers still get their turn.
    @discardableResult
    static func handle(
        _ providers: [NSItemProvider],
        record: SessionRecord,
        project: Project,
        onMessage: @escaping (String) -> Void = { _ in }
    ) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !candidates.isEmpty else { return false }

        let directory = URL(fileURLWithPath: record.workingDirectory(in: project))
            .appendingPathComponent(SessionImageDrop.directoryName)

        Task { @MainActor in
            var written: [String] = []
            for provider in candidates {
                if let name = await write(provider, into: directory) {
                    written.append(SessionImageDrop.relativePath(fileName: name))
                }
            }
            guard !written.isEmpty else {
                onMessage(String(localized: "Nothing in that drop was an image."))
                return
            }
            // Typed, not submitted: the drop is half a message, and the half
            // that says what the image is *for* is still being written.
            await TerminalRegistry.shared.typeText(
                SessionImageDrop.promptFragment(relativePaths: written),
                for: record.id,
                provider: record.provider
            )
            onMessage(
                written.count == 1
                    ? String(localized: "Attached \(written[0]).")
                    : String(localized: "Attached \(written.count) images.")
            )
        }
        return true
    }

    /// Writes one dropped item, returning the file name it landed under.
    private static func write(
        _ provider: NSItemProvider, into directory: URL
    ) async -> String? {
        guard let payload = await payload(of: provider) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let ignore = directory.appendingPathComponent(".gitignore")
            if !FileManager.default.fileExists(atPath: ignore.path) {
                try? Data(SessionImageDrop.ignoreContents.utf8).write(to: ignore)
            }
            let existing = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            )
            let name = SessionImageDrop.uniqueName(
                for: payload.name, at: Date(), existing: existing
            )
            try payload.data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private struct Payload {
        var name: String
        var data: Data
    }

    private static func payload(of provider: NSItemProvider) async -> Payload? {
        // A file first: it has a name worth keeping, and copying it is cheaper
        // than re-encoding the image.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadFileURL(provider),
           SessionImageDrop.isImage(fileName: url.lastPathComponent),
           let data = try? Data(contentsOf: url) {
            return Payload(name: url.lastPathComponent, data: data)
        }
        // No file: the image itself was dragged, so it is named after nothing
        // and has to be written as PNG.
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
}
