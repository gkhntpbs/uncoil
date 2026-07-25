import Foundation

/// Path arithmetic that survives macOS's two names for the same directory.
///
/// `FileManager.enumerator` hands back canonical paths (`/private/var/...`) while
/// a URL built from `temporaryDirectory` keeps the symlinked form (`/var/...`).
/// Comparing them as strings silently fails, and the fallback — using the last
/// path component — looks correct for files at the top level and quietly loses
/// the directory for everything nested.
enum FileTree {
    /// Canonical, comparable form of a path.
    static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Path of `url` relative to `root`, or nil when it is not inside it.
    static func relativePath(of url: URL, under root: URL) -> String? {
        let base = canonical(root)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = canonical(url)
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Every regular file under `root`, as paths relative to it.
    static func regularFiles(under root: URL) -> [(url: URL, relativePath: String)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var result: [(URL, String)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            guard let relative = relativePath(of: url, under: root) else { continue }
            result.append((url, relative))
        }
        return result.sorted { $0.1 < $1.1 }
    }
}
