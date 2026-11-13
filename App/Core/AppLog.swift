import Foundation
import os

/// Plain-text logs on disk, one file per area, for diagnosing a Mac that is
/// not the developer's.
///
/// `NSLog` lines vanish into the unified log, where reaching them needs
/// `log show` and a predicate nobody remembers, and most of Uncoil's quiet
/// failures were never logged at all. These files sit in
/// `~/Library/Application Support/Uncoil/Logs/`, rotate themselves, are added
/// to the debug bundle, and can be opened from Settings › About.
///
/// Every line is passed through `UsageCredentials.redacted` before it is
/// written: a log is something people attach to bug reports.
enum AppLog {
    enum Category: String, CaseIterable, Sendable {
        /// Usage and rate-limit tracking: every route tried, and why it failed.
        case usage
        /// Sessions: launch, exit, background commands.
        case sessions
        /// Everything else worth a line.
        case app
    }

    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return support
            .appendingPathComponent("Uncoil", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }()

    static func url(for category: Category) -> URL {
        directory.appendingPathComponent("\(category.rawValue).log")
    }

    /// Past this, the file becomes `<name>.1.log` and a new one starts.
    static let maxBytes = 2 * 1024 * 1024

    private static let queue = DispatchQueue(label: "com.gokhantopbas.uncoil.applog", qos: .utility)
    private static let system = Logger(subsystem: "com.gokhantopbas.uncoil", category: "applog")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Logs are off under UI tests so a test run does not write into the
    /// user's real log folder.
    static var isEnabled: Bool = !ProcessInfo.processInfo.arguments.contains("-ui-testing")

    static func log(_ category: Category, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = UsageCredentials.redacted(message())
        let stamp = formatter.string(from: Date())
        system.log("[\(category.rawValue, privacy: .public)] \(text, privacy: .public)")
        queue.async { append("\(stamp) \(text)\n", to: category) }
    }

    /// Waits for queued lines to reach disk — before a debug bundle reads them.
    static func flush() {
        queue.sync {}
    }

    private static func append(_ line: String, to category: Category) {
        let fm = FileManager.default
        let url = url(for: category)
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           size > maxBytes {
            let old = directory.appendingPathComponent("\(category.rawValue).1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
