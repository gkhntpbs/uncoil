import AppKit
import Foundation

/// What ⌘V does when the clipboard holds an image.
///
/// A choice rather than a fixed behaviour, because both answers are right
/// somewhere. An agent that reads images from its own paste handles it better
/// than any file can — when it works. Claude Code's does not always, and there
/// is nothing Uncoil can do about that from the outside except offer the route
/// that never fails: write the image down and paste its path.
enum ImagePasteMode: String, Codable, CaseIterable, Identifiable {
    /// Uncoil writes the image into the session's drop directory and pastes the
    /// path, exactly as a dropped image is handled.
    case attachFile
    /// ⌘V is left alone. The agent's own paste handling gets it.
    case agent

    var id: String { rawValue }

    /// The default is the reliable one. An agent's own paste is better when it
    /// works, but a paste that silently does nothing is worse than a path.
    static let `default` = ImagePasteMode.attachFile

    var title: String {
        switch self {
        case .attachFile: String(localized: "Save the image and paste its path")
        case .agent: String(localized: "Let the agent handle the paste")
        }
    }

    var detail: String {
        switch self {
        case .attachFile:
            String(localized: "The image is written into the session's working directory and its path is typed into the prompt — the same thing dropping an image does. Works with every agent.")
        case .agent:
            String(localized: "⌘V is passed straight through. Better when the agent reads pasted images well, and nothing at all when it does not.")
        }
    }
}

/// Reading the clipboard, and deciding whether ⌘V is ours to answer.
///
/// Pure over a list of type identifiers so the decision — which is the part
/// that can go wrong — is testable without a pasteboard.
enum ClipboardImagePaste {
    /// Whether Uncoil should answer this paste.
    ///
    /// Text wins over everything, and deliberately so. A clipboard carries
    /// several representations at once: rich text from a word processor can
    /// bring a rendered image along with it, and copying an image in a browser
    /// often puts its URL on as a string. Taking any clipboard that merely
    /// *mentions* an image would break the ordinary ⌘V of pasting a path or a
    /// sentence into a prompt — which is most of what ⌘V is for in a terminal,
    /// and a far worse failure than this one.
    ///
    /// The cost is that a browser's "copy image" may fall through to the agent.
    /// The case this exists for — a screenshot, which is what agents fumble —
    /// carries no string at all, and anything else can still be dragged in.
    static func shouldIntercept(types: [NSPasteboard.PasteboardType], mode: ImagePasteMode) -> Bool {
        guard mode == .attachFile else { return false }
        guard !types.contains(.string) else { return false }
        if types.contains(where: imageTypes.contains) { return true }
        // A file promise or a file URL is only ours when the file is an image;
        // that is checked from the URL itself, not from the type.
        return false
    }

    static let imageTypes: Set<NSPasteboard.PasteboardType> = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("public.heic"),
    ]

    /// Whether a clipboard of file URLs is one Uncoil should answer: every URL
    /// on it has to be an image, or ⌘V of a mixed selection would attach some
    /// of it and drop the rest.
    static func shouldIntercept(fileNames: [String], mode: ImagePasteMode) -> Bool {
        guard mode == .attachFile, !fileNames.isEmpty else { return false }
        return fileNames.allSatisfy(SessionImageDrop.isImage(fileName:))
    }
}
