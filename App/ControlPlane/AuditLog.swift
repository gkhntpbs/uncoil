import Foundation

/// Append-only JSONL audit trail at <AppSupport>/Uncoil/audit/<yyyy-mm-dd>.jsonl.
/// Never records argument *values* (which may hold secrets) — only argument
/// KEYS. One line per control-plane request decision.
final class AuditLog {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.gokhantopbas.uncoil.audit")

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    init(dataDirectory: URL) {
        directory = dataDirectory.appendingPathComponent("audit", isDirectory: true)
    }

    /// `decision` is a short token like "allow"/"deny"/"error". `argKeys` are
    /// the argument names present on the request (values are never logged).
    func record(
        requestID: String,
        callerSessionID: String?,
        capability: String,
        action: String,
        target: String?,
        decision: String,
        errorCode: String? = nil,
        argKeys: [String] = []
    ) {
        var entry: [String: Any] = [
            "ts": Self.isoFormatter.string(from: Date()),
            "request_id": requestID,
            "caller_session_id": callerSessionID as Any,
            "capability": capability,
            "action": action,
            "target": target as Any,
            "decision": decision,
            "arg_keys": argKeys.sorted(),
        ]
        if let errorCode { entry["error_code"] = errorCode }

        let day = Self.dayFormatter.string(from: Date())
        let fileURL = directory.appendingPathComponent("\(day).jsonl")
        queue.async {
            guard
                let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                var line = String(data: data, encoding: .utf8)
            else { return }
            line += "\n"
            guard let lineData = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(
                at: self.directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: lineData)
            } else {
                try? lineData.write(to: fileURL, options: .atomic)
            }
        }
    }
}
