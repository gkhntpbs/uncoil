import Foundation

/// Write-temp-rename atomic file write, mirroring the durability guarantee
/// ProjectStore relies on for its `.json` stores. A crash mid-write can only
/// leave the previous complete file or the new complete file — never a torn
/// one. The parent directory is created on demand.
enum AtomicFile {
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            // Replace destination; _replaceItem handles the rename atomically.
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}
