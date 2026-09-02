import Foundation

struct CodexSessionCandidate: Equatable {
    let id: String
    let cwd: String
    /// When Codex *began* this thread, from the thread's own `session_meta`.
    ///
    /// Not the file's modification time, which is what this used to sort on.
    /// A thread that is merely still being written to — another agent working
    /// in the same directory, which is the ordinary case in Uncoil — is
    /// modified constantly, so the newly launched session was not reliably the
    /// most recently touched file, and the oldest-first order this then took
    /// picked the *other* agent's thread. Binding to it meant resuming
    /// somebody else's conversation, or being told the thread already had an
    /// active writer, which is exactly what it had.
    let startedAt: Date
}

enum CodexSessionLocator {
    /// Threads begun in `cwd` since `startedAfter`, newest first.
    static func candidates(
        codexHome: URL,
        cwd: String,
        startedAfter: Date
    ) -> [CodexSessionCandidate] {
        let normalizedCWD = URL(fileURLWithPath: cwd).standardizedFileURL.path
        var matches: [CodexSessionCandidate] = []
        for root in candidateRoots(codexHome: codexHome) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in files {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey, .isRegularFileKey]
                      ),
                      values.isRegularFile == true,
                      // Still filtered on the file's own time first, purely to
                      // skip reading thousands of old rollouts: a thread begun
                      // after the launch cannot live in a file last written
                      // before it.
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= startedAfter,
                      let metadata = metadata(at: url),
                      metadata.startedAt >= startedAfter,
                      URL(fileURLWithPath: metadata.cwd).standardizedFileURL.path == normalizedCWD
                else { continue }
                matches.append(
                    CodexSessionCandidate(
                        id: metadata.id,
                        cwd: metadata.cwd,
                        startedAt: metadata.startedAt
                    )
                )
            }
        }
        return matches.sorted { $0.startedAt > $1.startedAt }
    }

    private static func candidateRoots(codexHome: URL, now: Date = .now) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        return [-1, 0, 1].compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else {
                return nil
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else { return nil }
            return codexHome
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    /// `2026-09-01T09:38:00.695Z`, as Codex writes it.
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseTimestamp(_ value: String) -> Date? {
        timestampFormatter.date(from: value)
            // A build that drops the milliseconds should not stop the session
            // being found.
            ?? ISO8601DateFormatter().date(from: value)
    }

    static func metadata(at url: URL) -> (id: String, cwd: String, startedAt: Date)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        for line in text.split(separator: "\n").prefix(12) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String,
                  let timestamp = payload["timestamp"] as? String,
                  let startedAt = parseTimestamp(timestamp)
            else { continue }
            return (id, cwd, startedAt)
        }
        return nil
    }
}
