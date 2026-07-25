import Foundation

enum TranscriptRetentionPolicy: String, Codable, CaseIterable, Identifiable {
    case disabled
    case sevenDays
    case thirtyDays
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: "Saklama"
        case .sevenDays: "7 gün"
        case .thirtyDays: "30 gün"
        case .forever: "Süresiz"
        }
    }

    var maximumAge: TimeInterval? {
        switch self {
        case .disabled: 0
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        case .forever: nil
        }
    }
}

final class SessionTranscriptStore: @unchecked Sendable {
    private let root: URL
    private let queue = DispatchQueue(label: "com.gkhntpbs.uncoil.transcripts")

    init(dataDirectory: URL) {
        root = dataDirectory.appendingPathComponent("transcripts", isDirectory: true)
    }

    func append(_ data: Data, sessionID: UUID, policy: TranscriptRetentionPolicy) {
        guard policy != .disabled, !data.isEmpty else { return }
        queue.async {
            try? FileManager.default.createDirectory(
                at: self.root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let file = self.url(for: sessionID)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(
                    atPath: file.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }

    func data(for sessionID: UUID) -> Data? {
        queue.sync {
            try? Data(contentsOf: url(for: sessionID))
        }
    }

    func clear(sessionID: UUID) {
        queue.sync {
            try? FileManager.default.removeItem(at: url(for: sessionID))
        }
    }

    func clearAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func prune(policy: TranscriptRetentionPolicy, now: Date = .now) {
        guard let maximumAge = policy.maximumAge else { return }
        queue.sync {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for file in files {
                guard let modified = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { continue }
                if maximumAge == 0 || now.timeIntervalSince(modified) > maximumAge {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func containsTranscripts() -> Bool {
        queue.sync {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: root.path)
            else { return false }
            return !files.isEmpty
        }
    }

    private func url(for sessionID: UUID) -> URL {
        root.appendingPathComponent("\(sessionID.uuidString).log")
    }
}
