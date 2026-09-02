import Foundation

/// Installs Uncoil's event hooks into `~/.hermes/config.yaml`.
///
/// The counterpart of `HookInstaller`, which does the same job for Claude Code,
/// and it keeps the same safety contract:
/// - a timestamped backup is written before every modification
/// - only entries whose command references the Uncoil helper are touched;
///   the user's own hooks are preserved line for line
/// - the rewritten block is re-read before it is written
///
/// Two things make Hermes different from Claude Code, and both are the reason
/// this is a separate file rather than a parameter on the other one.
///
/// **The events are not the same events.** Hermes fires seven hooks and Uncoil
/// understands five of them, but the correspondence is not the one the names
/// suggest — see `managedEvents` for the mapping and for the one that would
/// have been a real bug.
///
/// **Hermes asks before it runs a hook.** Every `(event, command)` pair prompts
/// once on a TTY and is then remembered in `shell-hooks-allowlist.json`. Uncoil
/// records its own pairs there when it installs, because the user clicking
/// "Connect" *is* that decision, and leaving it unanswered would mean the first
/// tool call of the next session stopping on a prompt behind the agent's own
/// output. What it never does is set `hooks_auto_accept`, which would approve
/// every future hook from anyone — the grant here is exactly the commands
/// Uncoil just wrote and nothing else.
enum HermesHookInstaller {
    /// Hermes' event names, and what each one means in Uncoil's vocabulary.
    ///
    /// Read off the firing sites in Hermes' own source rather than matched by
    /// name, because the names lie in one important place: `on_session_end` is
    /// documented as "fired at the very end of every run_conversation call" —
    /// that is the end of a *turn*, not of a session. Mapping it to `SessionEnd`
    /// would have marked every session terminated after its first reply. The
    /// real session boundary is `on_session_finalize`, which Hermes calls when
    /// it hard-closes a conversation.
    static let managedEvents: [(hermes: String, uncoil: String)] = [
        // Fired once when a brand-new session is created, not on continuation.
        ("on_session_start", "SessionStart"),
        // Carries `user_message` and `is_first_turn`, which is what names a
        // session after the first thing asked of it.
        ("pre_llm_call", "UserPromptSubmit"),
        ("pre_tool_call", "PreToolUse"),
        ("post_tool_call", "PostToolUse"),
        // End of turn. See above.
        ("on_session_end", "Stop"),
        ("on_session_finalize", "SessionEnd"),
    ]

    /// Uncoil's `Notification` has no counterpart here: Hermes has no hook that
    /// fires when it stops to ask for something. A session waiting on one of its
    /// approval prompts is therefore read from the terminal, as it is for every
    /// agent without hooks, rather than reported. Worth stating so nobody goes
    /// looking for the event that would carry it.
    static let unmappedUncoilEvents = ["Notification"]

    static let helperName = HookInstaller.helperName

    /// Uncoil has one notion of "are the hooks in", shared with `HookInstaller`
    /// rather than duplicated: `AgentIntegrationState.forHookCapableAgent`
    /// turns it into a row, and it must read the same for both agents.
    typealias Status = HookInstaller.Status

    enum InstallerError: LocalizedError {
        case helperMissing
        case configUnreadable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                "The uncoil-hook helper was not found in the app bundle."
            case .configUnreadable(let path):
                "\(path) could not be read, so the hooks cannot be installed."
            case .writeFailed(let detail):
                "config.yaml could not be written: \(detail)"
            }
        }
    }

    // MARK: - Locations

    /// `$HERMES_HOME`, else `~/.hermes` — the same order Hermes resolves it in,
    /// and the same one `HermesAdapter` uses.
    static var configRoot: URL {
        if let override = ProcessInfo.processInfo.environment["HERMES_HOME"]?
            .trimmingCharacters(in: .whitespaces), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes", isDirectory: true)
    }

    static var configURL: URL { configRoot.appendingPathComponent("config.yaml") }

    static var allowlistURL: URL {
        configRoot.appendingPathComponent("shell-hooks-allowlist.json")
    }

    static var helperURL: URL? { HookInstaller.helperURL }
    static var socketPath: String { HookInstaller.socketPath }

    private static var backupDirectory: URL {
        ProjectStore.defaultDirectory().appendingPathComponent("config-backups", isDirectory: true)
    }

    /// The command Hermes runs for one event.
    ///
    /// Every argument is quoted because Hermes splits this with `shlex`, and the
    /// helper's own path routinely contains spaces — an app bundle living under
    /// "…/M2 SSD/…" is not exotic, it is this machine.
    static func command(helperPath: String, uncoilEvent: String) -> String {
        "\"\(helperPath)\" \"\(socketPath)\" \"\(uncoilEvent)\""
    }

    // MARK: - Reading

    static func readConfig() throws -> String {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return "" }
        guard let data = FileManager.default.contents(atPath: configURL.path),
              let text = String(data: data, encoding: .utf8) else {
            throw InstallerError.configUnreadable(configURL.path)
        }
        return text
    }

    /// Pure: which managed events have an Uncoil hook in `config`.
    static func status(in config: String) -> Status {
        let installed = installedCommands(in: config)
        let missing = managedEvents
            .filter { installed[$0.hermes] == nil }
            .map(\.hermes)
        if missing.isEmpty { return .installed }
        if missing.count == managedEvents.count { return .notInstalled }
        return .partiallyInstalled(missing: missing)
    }

    /// Installed Uncoil commands that do not match what this bundle would write
    /// — the app was rebuilt elsewhere, moved, or its DerivedData was deleted.
    /// Left alone, every one of them logs a hook failure on every turn.
    static func staleCommands(in config: String, helperPath: String) -> [String] {
        installedCommands(in: config).compactMap { hermesEvent, command in
            guard let expected = managedEvents.first(where: { $0.hermes == hermesEvent })
                .map({ self.command(helperPath: helperPath, uncoilEvent: $0.uncoil) }),
                command != expected
            else { return nil }
            return command
        }
    }

    /// Everything a status check needs, from one read of the config.
    static func inspect() -> (status: Status, hasStaleCommands: Bool) {
        guard let config = try? readConfig() else { return (.notInstalled, false) }
        let stale = helperURL.map { !staleCommands(in: config, helperPath: $0.path).isEmpty }
            ?? false
        return (status(in: config), stale)
    }

    /// Uncoil's command under each Hermes event, keyed by event name.
    static func installedCommands(in config: String) -> [String: String] {
        var found: [String: String] = [:]
        for (event, items) in hookItems(in: config) {
            for item in items where isUncoilItem(item) {
                if let command = commandValue(in: item) { found[event] = command }
            }
        }
        return found
    }

    // MARK: - Writing

    static func install() throws {
        guard let helper = helperURL else { throw InstallerError.helperMissing }
        let config = try readConfig()
        try backupCurrentConfig()

        var block = hookBlock(in: config)
        for event in managedEvents {
            block.ensure(event.hermes)
            var existing = (block.events[event.hermes] ?? []).filter { !isUncoilItem($0) }
            existing.append(
                renderItem(command: command(helperPath: helper.path, uncoilEvent: event.uncoil))
            )
            block.events[event.hermes] = existing
        }
        let updated = HermesYAML.rewriteBlock(config, key: hooksKey, body: renderBody(block))
        try write(updated)
        try recordApprovals(helperPath: helper.path)
    }

    static func uninstall() throws {
        let config = try readConfig()
        guard !installedCommands(in: config).isEmpty else { return }
        try backupCurrentConfig()

        var block = hookBlock(in: config)
        for event in block.events.keys {
            let kept = (block.events[event] ?? []).filter { !isUncoilItem($0) }
            block.events[event] = kept.isEmpty ? nil : kept
        }
        block.order = block.order.filter { block.events[$0] != nil }
        let body = renderBody(block)
        try write(HermesYAML.rewriteBlock(config, key: hooksKey, body: body.isEmpty ? nil : body))
        try removeApprovals()
    }

    /// Re-points existing Uncoil entries at the running bundle's helper, and
    /// re-grants them: the allowlist is keyed on the whole command string, so a
    /// repaired path is an unapproved pair until it is recorded again.
    @discardableResult
    static func repairStalePaths() throws -> Int {
        guard let helper = helperURL else { return 0 }
        let config = try readConfig()
        guard !staleCommands(in: config, helperPath: helper.path).isEmpty else { return 0 }
        try backupCurrentConfig()

        var block = hookBlock(in: config)
        var repaired = 0
        for event in managedEvents {
            guard var existing = block.events[event.hermes] else { continue }
            let expected = command(helperPath: helper.path, uncoilEvent: event.uncoil)
            for index in existing.indices where isUncoilItem(existing[index]) {
                guard commandValue(in: existing[index]) != expected else { continue }
                existing[index] = renderItem(command: expected)
                repaired += 1
            }
            block.events[event.hermes] = existing
        }
        guard repaired > 0 else { return 0 }
        try write(HermesYAML.rewriteBlock(config, key: hooksKey, body: renderBody(block)))
        try recordApprovals(helperPath: helper.path)
        return repaired
    }

    // MARK: - Consent

    /// Records Uncoil's own `(event, command)` pairs in Hermes' allowlist.
    ///
    /// Deliberately narrow: only the pairs just written, never
    /// `hooks_auto_accept`, and the user's existing approvals are carried over
    /// untouched. `script_mtime_at_approval` is filled in because Hermes' own
    /// `hooks doctor` reports on it; it does not gate anything, so a rebuilt
    /// helper stays approved.
    static func recordApprovals(helperPath: String) throws {
        try writeAllowlist(
            granting(
                helperPath: helperPath,
                into: loadAllowlist(),
                now: ISO8601DateFormatter.allowlistTimestamp.string(from: .now),
                helperModifiedAt: helperModifiedAt(helperPath)
            )
        )
    }

    /// Pure counterpart, so what lands in a file that decides which commands may
    /// run is unit-testable rather than inspected by hand.
    ///
    /// Uncoil's own previous entries go — including ones naming a helper path
    /// that has since moved, which would otherwise accumulate one dead grant per
    /// rebuild — and everybody else's are carried over untouched.
    static func granting(
        helperPath: String,
        into existing: [String: Any],
        now: String,
        helperModifiedAt: String?
    ) -> [String: Any] {
        var root = existing
        var approvals = (root["approvals"] as? [[String: Any]]) ?? []
        approvals.removeAll { entry in
            guard let command = entry["command"] as? String else { return false }
            return command.contains(helperName)
        }
        for pair in managedEvents {
            var entry: [String: Any] = [
                "event": pair.hermes,
                "command": command(helperPath: helperPath, uncoilEvent: pair.uncoil),
                "approved_at": now,
            ]
            entry["script_mtime_at_approval"] = helperModifiedAt ?? NSNull()
            approvals.append(entry)
        }
        root["approvals"] = approvals
        return root
    }

    static func removeApprovals() throws {
        var root = loadAllowlist()
        guard var approvals = root["approvals"] as? [[String: Any]] else { return }
        approvals.removeAll { ($0["command"] as? String)?.contains(helperName) == true }
        root["approvals"] = approvals
        try writeAllowlist(root)
    }

    private static func loadAllowlist() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: allowlistURL.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func writeAllowlist(_ root: [String: Any]) throws {
        do {
            try FileManager.default.createDirectory(
                at: configRoot, withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: allowlistURL, options: .atomic)
            // Hermes writes this owner-only; an approval file the rest of the
            // machine can edit is an approval file that means nothing.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: allowlistURL.path
            )
        } catch {
            throw InstallerError.writeFailed(error.localizedDescription)
        }
    }

    private static func helperModifiedAt(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return ISO8601DateFormatter.allowlistTimestamp.string(from: date)
    }

    // MARK: - The hooks block

    static let hooksKey = "hooks"

    /// One sequence item, as the lines it occupies. Kept as lines rather than
    /// parsed into a model because an item Uncoil does not own has to come back
    /// exactly as the user wrote it, comments and all.
    typealias Item = [String]

    /// The `hooks:` block, parsed far enough to put it back.
    ///
    /// Comments are the reason this is a struct rather than a dictionary. A
    /// comment above a hook explains why the hook is there, and "the user's own
    /// hooks are preserved" is not honoured by a rewrite that keeps the command
    /// and drops the sentence explaining it. So a comment travels with the item
    /// it introduces, and the ones above the first event — which belong to the
    /// block rather than to any entry — are kept separately.
    struct Block {
        /// Comments between `hooks:` and its first event key.
        var leading: [String] = []
        var events: [String: [Item]] = [:]
        /// Event keys in the order they were found, so an event Uncoil does not
        /// manage keeps its place instead of being re-sorted.
        var order: [String] = []

        mutating func append(_ item: Item, to event: String) {
            if events[event] == nil { order.append(event) }
            events[event, default: []].append(item)
        }

        mutating func ensure(_ event: String) {
            if events[event] == nil {
                events[event] = []
                order.append(event)
            }
        }
    }

    static func hookBlock(in config: String) -> Block {
        let body = HermesYAML.blockBody(hooksKey, in: config)
        var block = Block()
        guard !body.isEmpty else { return block }
        let eventIndent = body
            .first { !HermesYAML.isBlankOrComment($0) }
            .map(HermesYAML.indentation(of:)) ?? 2

        var currentEvent: String?
        var currentItem: Item = []
        /// Comments seen since the last item began — they introduce the next one.
        var pending: [String] = []

        func flushItem() {
            guard !currentItem.isEmpty else { return }
            if let event = currentEvent {
                block.append(currentItem, to: event)
            }
            currentItem = []
        }

        func flushPending() {
            guard !pending.isEmpty else { return }
            // A trailing comment with no item after it: keep it as an item of
            // its own rather than lose it. It carries no command, so it is
            // never mistaken for Uncoil's and never repaired.
            if let event = currentEvent {
                block.append(pending, to: event)
            } else {
                block.leading.append(contentsOf: pending)
            }
            pending = []
        }

        for line in body {
            // Buffered rather than appended to whatever came before, because a
            // comment between two items introduces the *second* one. Which of
            // the two it belongs to is only known at the next non-comment line:
            // a `- ` means it was a heading for the item starting there, and a
            // continuation line means it was interior to the item already open.
            if HermesYAML.isBlankOrComment(line) {
                pending.append(line)
                continue
            }
            let indent = HermesYAML.indentation(of: line)
            if indent == eventIndent, let key = HermesYAML.mappingKey(line) {
                flushItem()
                flushPending()
                currentEvent = key
                block.ensure(key)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                flushItem()
                currentItem = pending
            } else {
                currentItem.append(contentsOf: pending)
            }
            pending = []
            currentItem.append(line)
        }
        // A comment with nothing after it trails the item it followed.
        currentItem.append(contentsOf: pending)
        pending = []
        flushItem()
        flushPending()
        return block
    }

    /// The events alone, for callers that do not care about ordering or
    /// comments.
    static func hookItems(in config: String) -> [String: [Item]] {
        hookBlock(in: config).events
    }

    static func isUncoilItem(_ item: Item) -> Bool {
        item.contains { $0.contains(helperName) }
    }

    /// The `command:` value of an item, unquoted.
    static func commandValue(in item: Item) -> String? {
        for line in item {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let withoutDash = trimmed.hasPrefix("- ")
                ? String(trimmed.dropFirst(2))
                : trimmed
            guard let pair = HermesYAML.keyValue(withoutDash),
                  pair.key == "command",
                  let value = pair.value else { continue }
            return value.stringValue ?? HermesYAML.rendered(value)
        }
        return nil
    }

    static func renderItem(command: String, indent: Int = 2) -> Item {
        // No `matcher`: absent means "every tool", which is what Uncoil wants
        // and what Hermes' own `ShellHookSpec.matches_tool` returns for nil.
        // A `timeout` all the same — the helper fails open in well under a
        // second, and an explicit ceiling means a wedged socket can never be
        // the reason a turn stalls.
        let pad = String(repeating: " ", count: indent * 2)
        return [
            "\(pad)- command: \(HermesYAML.quote(command))",
            "\(pad)  timeout: 5",
        ]
    }

    /// Renders the whole block body: managed events first in their documented
    /// order, then whatever else the user had, in the order they had it.
    static func renderBody(_ block: Block, indent: Int = 2) -> [String] {
        let pad = String(repeating: " ", count: indent)
        let ordered = managedEvents.map(\.hermes)
        let extra = block.order.filter { !ordered.contains($0) }
        var lines = block.leading
        for event in ordered + extra {
            guard let eventItems = block.events[event], !eventItems.isEmpty else { continue }
            lines.append("\(pad)\(event):")
            for item in eventItems { lines.append(contentsOf: item) }
        }
        return lines
    }

    /// Convenience for callers holding only the events.
    static func renderBody(_ items: [String: [Item]], indent: Int = 2) -> [String] {
        var block = Block()
        for event in managedEvents.map(\.hermes) + items.keys.sorted() {
            guard let eventItems = items[event] else { continue }
            for item in eventItems { block.append(item, to: event) }
        }
        return renderBody(block, indent: indent)
    }

    // MARK: - Internals

    private static func backupCurrentConfig() throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        try FileManager.default.createDirectory(
            at: backupDirectory, withIntermediateDirectories: true
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "hermes-config-\(formatter.string(from: .now)).yaml"
        try FileManager.default.copyItem(
            at: configURL, to: backupDirectory.appendingPathComponent(name)
        )
    }

    private static func write(_ config: String) throws {
        // Re-read what is about to be written: if the block cannot be found
        // again, the rewrite produced something Hermes would not parse, and
        // stopping here leaves the user's file as it was.
        guard config.isEmpty || HermesYAML.section(hooksKey, in: config) != nil
            || installedCommands(in: config).isEmpty else {
            throw InstallerError.writeFailed("the rewritten hooks block could not be re-read")
        }
        do {
            try FileManager.default.createDirectory(
                at: configRoot, withIntermediateDirectories: true
            )
            try Data(config.utf8).write(to: configURL, options: .atomic)
        } catch {
            throw InstallerError.writeFailed(error.localizedDescription)
        }
    }
}

private extension ISO8601DateFormatter {
    /// Hermes writes `...Z`, which is what `Date.isoformat().replace("+00:00","Z")`
    /// produces; matching it keeps `hermes hooks list` readable.
    static let allowlistTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
