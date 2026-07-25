import Foundation

struct CodexSessionCandidate: Equatable {
    let id: String
    let cwd: String
    let modifiedAt: Date
}

enum CodexSessionLocator {
    static func candidates(
        codexHome: URL,
        cwd: String,
        modifiedAfter: Date
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
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= modifiedAfter,
                      let metadata = metadata(at: url),
                      URL(fileURLWithPath: metadata.cwd).standardizedFileURL.path == normalizedCWD
                else { continue }
                matches.append(
                    CodexSessionCandidate(
                        id: metadata.id,
                        cwd: metadata.cwd,
                        modifiedAt: modifiedAt
                    )
                )
            }
        }
        return matches.sorted { $0.modifiedAt < $1.modifiedAt }
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

    private static func metadata(at url: URL) -> (id: String, cwd: String)? {
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
                  let cwd = payload["cwd"] as? String
            else { continue }
            return (id, cwd)
        }
        return nil
    }
}
