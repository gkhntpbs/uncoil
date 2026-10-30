import SwiftUI

@MainActor
final class SessionTitlePresentation: ObservableObject {
    static let shared = SessionTitlePresentation()

    private struct Entry {
        let original: String
        let full: String
    }

    @Published private var entries: [UUID: Entry] = [:]
    private var pending: Set<UUID> = []

    func title(for record: SessionRecord) -> String {
        guard let entry = entries[record.id], entry.original == record.title else { return record.displayTitle }
        return entry.full
    }

    func resolve(_ record: SessionRecord, project: Project, settings: SettingsStore) async {
        guard entries[record.id]?.original != record.title, !pending.contains(record.id),
              let sessionID = record.providerSessionID, UUID(uuidString: sessionID) != nil else { return }
        let prefix = "\(record.provider.rawValue): "
        let stored = record.title.hasPrefix(prefix) ? String(record.title.dropFirst(prefix.count)) : record.title
        guard stored.count == 42, stored.hasSuffix("…") else { return }
        let account = settings.account(id: record.accountID)
        let provider = record.provider
        let directories: [URL?] = account.map { [$0.configDirectory(profilesRoot: settings.profilesRootURL)] }
            ?? [nil] + settings.accounts(for: provider).compactMap {
                $0.configDirectory(profilesRoot: settings.profilesRootURL)
            }.map(Optional.some)
        let cwd = record.workingDirectory(in: project)
        pending.insert(record.id)
        defer { pending.remove(record.id) }
        let full = await Task.detached(priority: .utility) { () -> String? in
            for directory in directories {
                let transcript: URL
                switch provider {
                case .claude:
                    let url = ClaudeSessionStore.transcriptURL(
                        configDirectory: directory ?? ClaudeSessionStore.defaultConfigDirectory(),
                        cwd: cwd, sessionID: sessionID
                    )
                    guard let summary = ClaudeTranscriptSummary.read(at: url), summary.sessionID == sessionID,
                          SessionImportPlacement.normalized(summary.cwd) == SessionImportPlacement.normalized(cwd) else { continue }
                    transcript = url
                case .codex:
                    guard let url = CodexSessionStore.transcriptURL(
                        codexHome: directory ?? CodexSessionStore.defaultHome(), threadID: sessionID
                    ), let summary = CodexRolloutSummary.read(at: url), summary.threadID == sessionID,
                          SessionImportPlacement.normalized(summary.cwd) == SessionImportPlacement.normalized(cwd) else { continue }
                    transcript = url
                default: return nil
                }
                if let title = Self.expandedTitle(in: transcript, provider: provider, stored: stored) {
                    return title
                }
            }
            return nil
        }.value
        if let full {
            entries[record.id] = Entry(original: record.title, full: full)
        }
    }

    nonisolated private static func expandedTitle(in url: URL, provider: AgentProvider, stored: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        var skipping = false
        var best: String?
        var bestDistance = 17
        var ambiguous = false
        let target = normalized(String(stored.dropLast()))
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                if !skipping,
                   let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    let content: Any?
                    switch provider {
                    case .claude:
                        if object["type"] as? String == "user", object["isMeta"] as? Bool != true,
                           object["isSidechain"] as? Bool != true {
                            content = (object["message"] as? [String: Any])?["content"]
                        } else { content = nil }
                    case .codex:
                        if object["type"] as? String == "response_item",
                           let item = object["payload"] as? [String: Any],
                           item["type"] as? String == "message", item["role"] as? String == "user" {
                            content = item["content"]
                        } else { content = nil }
                    default: content = nil
                    }
                    let texts = (content as? String).map { [$0] }
                        ?? (content as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
                    for text in texts {
                        let prompt: String
                        switch SessionImportScanner.classify(text) {
                        case .typed(let value), .pasted(let value): prompt = value
                        case .ignored: continue
                        }
                        guard let candidate = SessionAutoTitle.candidate(from: prompt), candidate.count > stored.count else { continue }
                        let prefix = normalized(String(candidate.prefix(41)))
                        let distance = editDistance(target, prefix)
                        guard distance <= 16, distance <= max(target.count, prefix.count) * 2 / 5 else { continue }
                        let full = MarkdownInline.plain(candidate)
                        if distance < bestDistance {
                            best = full
                            bestDistance = distance
                            ambiguous = false
                        } else if distance == bestDistance, best != full {
                            ambiguous = true
                        }
                    }
                }
                buffer.removeSubrange(...end)
                skipping = false
            }
            if buffer.count > 8 * 1024 * 1024 {
                buffer.removeAll(keepingCapacity: false)
                skipping = true
            }
        }
        return ambiguous ? nil : best
    }

    nonisolated private static func normalized(_ text: String) -> [Character] {
        Array(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR")))
    }

    nonisolated private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1]
            for (j, right) in rhs.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[rhs.count]
    }

}
