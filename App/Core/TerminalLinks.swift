import AppKit
import Foundation

/// How links printed in a session terminal are opened.
///
/// Agents put links in front of you in two ways, and both have to work:
/// - **Explicit (OSC 8) hyperlinks**: the CLI wraps visible text in an escape
///   sequence carrying a target. Codex points file citations at an editor URI
///   (`vscode://file/<abs>:<line>`, chosen by its `file_opener` setting); Claude
///   Code emits `file://` links — sometimes with `:line` glued onto the path, or
///   with no scheme at all — but only when it believes the terminal supports
///   them, which `FORCE_HYPERLINK=1` tells it.
/// - **Plain text**: a URL or a path like `App/UI/Foo.swift:42` that merely
///   looks like one. SwiftTerm finds those itself.
///
/// Either way the click arrives as one string. This turns it into "a web page"
/// or "a file, maybe at a line" and opens it where the user asked.
struct TerminalLinkPrefs: Codable, Equatable {
    /// ⌃-click opens a link too (⌘-click always does). On by default.
    var controlClickOpens: Bool = true
    /// Where file links go.
    var fileTarget: TerminalFileLinkTarget = .editor
    /// Bundle id of the browser web links open in; nil = the system default.
    var browserBundleID: String? = nil
    /// Sets `FORCE_HYPERLINK=1` in new sessions, so CLIs that only emit
    /// clickable links for terminals they recognise emit them here too.
    var advertiseHyperlinks: Bool = true

    static let `default` = TerminalLinkPrefs()
}

enum TerminalFileLinkTarget: String, Codable, CaseIterable, Identifiable {
    /// The editor chosen under Settings › General, at the line when known.
    case editor
    /// Whatever macOS opens the file type with.
    case systemDefault
    /// Reveal in Finder.
    case finder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .editor: String(localized: "Preferred editor")
        case .systemDefault: String(localized: "Default app for the file type")
        case .finder: String(localized: "Reveal in Finder")
        }
    }
}

/// What a clicked link turned out to be. Pure, so it can be unit-tested.
enum TerminalLinkTarget: Equatable {
    case web(URL)
    case file(path: String, line: Int?, column: Int?)
    /// Any other scheme (mailto:, ssh:, an app's own URL) — handed to macOS.
    case other(URL)

    /// Editor URI schemes CLIs use for "open this file" links.
    static let editorSchemes: Set<String> = [
        "vscode", "vscode-insiders", "cursor", "windsurf", "zed", "vscodium",
    ]

    /// - Parameters:
    ///   - link: the string SwiftTerm reported (OSC 8 target or matched text).
    ///   - directory: what relative paths are relative to — the session's folder.
    ///   - exists: file-existence check, injectable for tests.
    static func resolve(
        _ rawLink: String,
        relativeTo directory: String?,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> TerminalLinkTarget? {
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\"`<>()[]"))
        guard !link.isEmpty else { return nil }

        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            switch scheme {
            case "http", "https":
                return .web(url)
            case "file":
                // `file://host/path` — the host is this machine or nothing.
                let path = url.path.removingPercentEncoding ?? url.path
                return fileTarget(path + lineSuffix(of: url), relativeTo: directory, exists: exists)
            default:
                if editorSchemes.contains(scheme), url.host?.lowercased() == "file" {
                    // vscode://file/<abs path>[:line[:col]]
                    let path = (url.path.removingPercentEncoding ?? url.path)
                    return fileTarget(path, relativeTo: directory, exists: exists)
                }
                // `Foo.swift:42` parses as scheme "Foo.swift"; a real file wins.
                if let file = fileTarget(link, relativeTo: directory, exists: exists) {
                    return file
                }
                return .other(url)
            }
        }
        return fileTarget(link, relativeTo: directory, exists: exists)
    }

    /// `#L42` / `#L42C3` fragments some tools use instead of `:42`.
    private static func lineSuffix(of url: URL) -> String {
        guard let fragment = url.fragment, fragment.hasPrefix("L") else { return "" }
        let parts = fragment.dropFirst().split(separator: "C")
        return parts.map { ":\($0)" }.joined()
    }

    /// A path, possibly relative, possibly with `:line[:col]`, `(line,col)` or
    /// `#Lline` attached.
    static func fileTarget(
        _ raw: String,
        relativeTo directory: String?,
        exists: (String) -> Bool
    ) -> TerminalLinkTarget? {
        var text = raw
        var line: Int?
        var column: Int?

        // path#L12 / path#L12C3
        if let hash = text.range(of: "#L", options: .backwards) {
            let tail = text[hash.upperBound...].split(separator: "C")
            if let first = tail.first, let l = Int(first) {
                line = l
                column = tail.count > 1 ? Int(tail[1]) : nil
                text = String(text[..<hash.lowerBound])
            }
        }
        // path(12,3) / path(12)
        if line == nil, text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
            let nums = inner.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let first = nums.first, let l = first {
                line = l
                column = nums.count > 1 ? nums[1] : nil
                text = String(text[..<open])
            }
        }
        // path:12 / path:12:3 — only when the path without it is the real one,
        // so a file genuinely named `a:1` still opens.
        if line == nil {
            var stripped = text
            var numbers: [Int] = []
            while numbers.count < 2, let colon = stripped.lastIndex(of: ":"),
                  let n = Int(stripped[stripped.index(after: colon)...]) {
                numbers.insert(n, at: 0)
                stripped = String(stripped[..<colon])
            }
            if !numbers.isEmpty, !exists(absolute(text, relativeTo: directory)) {
                text = stripped
                line = numbers[0]
                column = numbers.count > 1 ? numbers[1] : nil
            }
        }
        // Trailing punctuation that prose puts after a path.
        while let last = text.last, ".,;:".contains(last), !exists(absolute(text, relativeTo: directory)) {
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }
        let path = absolute(text, relativeTo: directory)
        guard exists(path) else { return nil }
        return .file(path: path, line: line, column: column)
    }

    static func absolute(_ path: String, relativeTo directory: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        guard let directory, !directory.isEmpty else { return expanded }
        return ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}

/// Opens resolved terminal links according to the user's settings.
@MainActor
enum TerminalLinkOpener {
    /// Pushed by `SettingsStore` whenever settings load or change, so the
    /// terminal delegates — which have no store of their own — read live values.
    static var prefs = TerminalLinkPrefs.default
    static var editor: PreferredEditor = .vscode

    static func configure(prefs: TerminalLinkPrefs, editor: PreferredEditor) {
        self.prefs = prefs
        self.editor = editor
    }

    /// Opens `link`; returns false when it resolved to nothing openable.
    @discardableResult
    static func open(_ link: String, relativeTo directory: String?) -> Bool {
        guard let target = TerminalLinkTarget.resolve(link, relativeTo: directory) else {
            // Last resort: something macOS itself understands.
            if let url = URL(string: link), url.scheme != nil {
                return NSWorkspace.shared.open(url)
            }
            NSSound.beep()
            return false
        }
        switch target {
        case .web(let url):
            openWeb(url)
        case .other(let url):
            NSWorkspace.shared.open(url)
        case .file(let path, let line, let column):
            openFile(path, line: line, column: column)
        }
        return true
    }

    private static func openWeb(_ url: URL) {
        if let id = prefs.browserBundleID,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func openFile(_ path: String, line: Int?, column: Int?) {
        let fileURL = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        switch prefs.fileTarget {
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        case .systemDefault:
            NSWorkspace.shared.open(fileURL)
        case .editor:
            let editor = Self.editor
            guard editor.isInstalled else {
                NSWorkspace.shared.open(fileURL)
                return
            }
            if isDirectory.boolValue {
                editor.openProject(fileURL)
                return
            }
            if let uri = lineURI(for: editor, path: path, line: line, column: column) {
                NSWorkspace.shared.open(uri)
            } else {
                editor.open(fileURL)
            }
        }
    }

    /// An editor URI that lands on the line, for editors that have one.
    static func lineURI(for editor: PreferredEditor, path: String, line: Int?, column: Int?) -> URL? {
        guard let line else { return nil }
        let position = column.map { ":\(line):\($0)" } ?? ":\(line)"
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        switch editor {
        case .vscode: return URL(string: "vscode://file\(encoded)\(position)")
        case .cursor: return URL(string: "cursor://file\(encoded)\(position)")
        case .zed: return URL(string: "zed://file\(encoded)\(position)")
        case .sublime:
            let file = URL(fileURLWithPath: path).absoluteString
            let query = file.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? file
            return URL(string: "subl://open?url=\(query)&line=\(line)" + (column.map { "&column=\($0)" } ?? ""))
        case .textedit, .xcode:
            return nil
        }
    }

    /// Installed browsers, for the settings picker.
    static func installedBrowsers() -> [(bundleID: String, name: String)] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var seen: Set<String> = []
        var result: [(bundleID: String, name: String)] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            result.append((bundleID: id, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A terminal view that knows which folder its relative links are relative
/// to, and can open the link under a ⌃-click (SwiftTerm handles ⌘-click).
@MainActor
protocol TerminalLinkContext: AnyObject {
    var linkDirectory: String? { get set }
}
