import XCTest
@testable import Uncoil

/// The Hermes side of the hook bridge, driven over strings rather than over the
/// real `~/.hermes/config.yaml`: everything that decides what gets written is
/// pure, so none of this needs a Hermes install.
final class HermesHookInstallerTests: XCTestCase {
    private let helper = "/Applications/Uncoil.app/Contents/Helpers/uncoil-hook"

    // MARK: - The mapping

    /// The one that would have been a real bug. Hermes' `on_session_end` is
    /// documented in its own source as "fired at the very end of every
    /// run_conversation call" — the end of a *turn*. Mapping it to `SessionEnd`
    /// would mark every session terminated after its first reply.
    func testEndOfTurnIsNotMistakenForEndOfSession() {
        let map = Dictionary(
            uniqueKeysWithValues: HermesHookInstaller.managedEvents.map { ($0.hermes, $0.uncoil) }
        )
        XCTAssertEqual(map["on_session_end"], "Stop")
        XCTAssertEqual(map["on_session_finalize"], "SessionEnd")
    }

    func testEveryMappedNameIsAnEventUncoilUnderstands() {
        for pair in HermesHookInstaller.managedEvents {
            XCTAssertNotNil(
                HookEvent.Kind(rawValue: pair.uncoil),
                "\(pair.hermes) maps to \(pair.uncoil), which the reducer has no case for"
            )
        }
    }

    /// Hermes has no hook that fires when it stops to ask for something, so
    /// `Notification` has no source. Stated in the type and pinned here so a
    /// later reader does not go looking for the event that would carry it.
    func testTheUnmappedEventIsTheOneWithNoSource() {
        let mapped = Set(HermesHookInstaller.managedEvents.map(\.uncoil))
        let all = Set(HookEvent.Kind.allNames)
        XCTAssertEqual(all.subtracting(mapped), Set(HermesHookInstaller.unmappedUncoilEvents))
    }

    // MARK: - The command

    /// Hermes splits the command with `shlex`, and the helper's own path
    /// routinely contains spaces — an app bundle under "…/M2 SSD/…" is this
    /// machine, not a hypothetical.
    func testEveryArgumentIsQuotedForShlex() {
        let command = HermesHookInstaller.command(
            helperPath: "/Volumes/M2 SSD/Uncoil.app/Contents/Helpers/uncoil-hook",
            uncoilEvent: "SessionStart"
        )
        XCTAssertTrue(command.hasPrefix("\"/Volumes/M2 SSD/"), command)
        XCTAssertTrue(command.hasSuffix("\"SessionStart\""), command)
    }

    // MARK: - Writing

    /// Mirrors `install()` without touching disk.
    private func installed(into config: String) -> String {
        var block = HermesHookInstaller.hookBlock(in: config)
        for event in HermesHookInstaller.managedEvents {
            block.ensure(event.hermes)
            var existing = (block.events[event.hermes] ?? [])
                .filter { !HermesHookInstaller.isUncoilItem($0) }
            existing.append(
                HermesHookInstaller.renderItem(
                    command: HermesHookInstaller.command(
                        helperPath: helper, uncoilEvent: event.uncoil
                    )
                )
            )
            block.events[event.hermes] = existing
        }
        return HermesYAML.rewriteBlock(
            config, key: HermesHookInstaller.hooksKey,
            body: HermesHookInstaller.renderBody(block)
        )
    }

    func testInstallingIntoAnEmptyConfigCoversEveryManagedEvent() {
        let config = installed(into: "")
        XCTAssertEqual(HermesHookInstaller.status(in: config), .installed)
        for event in HermesHookInstaller.managedEvents {
            XCTAssertEqual(
                HermesHookInstaller.installedCommands(in: config)[event.hermes],
                HermesHookInstaller.command(helperPath: helper, uncoilEvent: event.uncoil)
            )
        }
    }

    /// The safety contract: the user's own hooks come back line for line, and
    /// so does everything outside the block.
    func testTheUsersOwnHooksSurviveAnInstall() {
        let original = """
        model:
          provider: openrouter

        hooks:
          pre_tool_call:
            # never let it near rm -rf
            - matcher: "terminal"
              command: "~/.hermes/agent-hooks/block-rm-rf.sh"
              timeout: 10
          subagent_stop:
            - command: "~/.hermes/agent-hooks/log-orchestration.sh"

        hooks_auto_accept: false
        """
        let config = installed(into: original)

        XCTAssertTrue(config.contains("# never let it near rm -rf"))
        XCTAssertTrue(config.contains("matcher: \"terminal\""))
        XCTAssertTrue(config.contains("block-rm-rf.sh"))
        XCTAssertTrue(config.contains("log-orchestration.sh"))
        // An event Uncoil does not manage keeps its entries.
        XCTAssertEqual(HermesHookInstaller.hookItems(in: config)["subagent_stop"]?.count, 1)
        XCTAssertTrue(config.contains("provider: openrouter"))
        XCTAssertTrue(config.contains("hooks_auto_accept: false"))
        XCTAssertEqual(HermesHookInstaller.status(in: config), .installed)
    }

    func testInstallingTwiceDoesNotDuplicateEntries() {
        let once = installed(into: "")
        let twice = installed(into: once)
        for (_, items) in HermesHookInstaller.hookItems(in: twice) {
            XCTAssertEqual(items.filter(HermesHookInstaller.isUncoilItem).count, 1)
        }
    }

    func testAPartialInstallNamesTheMissingEvents() {
        var items: [String: [HermesHookInstaller.Item]] = [:]
        let first = HermesHookInstaller.managedEvents[0]
        items[first.hermes] = [
            HermesHookInstaller.renderItem(
                command: HermesHookInstaller.command(helperPath: helper, uncoilEvent: first.uncoil)
            )
        ]
        let config = HermesYAML.rewriteBlock(
            "", key: HermesHookInstaller.hooksKey, body: HermesHookInstaller.renderBody(items)
        )
        guard case .partiallyInstalled(let missing) = HermesHookInstaller.status(in: config) else {
            return XCTFail("one of six events installed is a partial install")
        }
        XCTAssertEqual(
            Set(missing),
            Set(HermesHookInstaller.managedEvents.dropFirst().map(\.hermes))
        )
    }

    func testNoHooksAtAllIsNotInstalledRatherThanPartial() {
        XCTAssertEqual(HermesHookInstaller.status(in: ""), .notInstalled)
        XCTAssertEqual(
            HermesHookInstaller.status(in: "hooks:\n  pre_tool_call:\n    - command: \"mine.sh\"\n"),
            .notInstalled
        )
    }

    // MARK: - Stale paths

    /// A stale path is the case that looks fine and fails on every turn: the
    /// hooks are there, so nothing offers to install them, and the helper they
    /// name is gone.
    func testAHelperThatMovedIsReportedAsStale() {
        let config = installed(into: "")
        XCTAssertTrue(HermesHookInstaller.staleCommands(in: config, helperPath: helper).isEmpty)
        let moved = HermesHookInstaller.staleCommands(
            in: config, helperPath: "/Users/someone/Build/Uncoil.app/Contents/Helpers/uncoil-hook"
        )
        XCTAssertEqual(moved.count, HermesHookInstaller.managedEvents.count)
    }

    /// A user's own hook is never "stale" — it is not Uncoil's to repair.
    func testSomebodyElsesHookIsNeverStale() {
        let config = """
        hooks:
          pre_tool_call:
            - command: "~/.hermes/agent-hooks/mine.sh"
        """
        XCTAssertTrue(HermesHookInstaller.staleCommands(in: config, helperPath: helper).isEmpty)
    }

    // MARK: - Parsing the block

    func testItemsAreSplitAtTheirOwnDashes() {
        let config = """
        hooks:
          pre_tool_call:
            - matcher: "a"
              command: "one.sh"
              timeout: 10
            - command: "two.sh"
          post_tool_call:
            - command: "three.sh"
        """
        let items = HermesHookInstaller.hookItems(in: config)
        XCTAssertEqual(items["pre_tool_call"]?.count, 2)
        XCTAssertEqual(items["post_tool_call"]?.count, 1)
        XCTAssertEqual(
            HermesHookInstaller.commandValue(in: items["pre_tool_call"]![0]), "one.sh"
        )
        XCTAssertEqual(
            HermesHookInstaller.commandValue(in: items["pre_tool_call"]![1]), "two.sh"
        )
    }

    /// The command sits on the same line as the dash when it is the item's
    /// first key, which is exactly how Uncoil writes its own.
    func testACommandOnTheDashLineIsRead() {
        let item = HermesHookInstaller.renderItem(command: "\"/bin/uncoil-hook\" \"/s.sock\" \"Stop\"")
        XCTAssertEqual(
            HermesHookInstaller.commandValue(in: item),
            "\"/bin/uncoil-hook\" \"/s.sock\" \"Stop\""
        )
        XCTAssertTrue(HermesHookInstaller.isUncoilItem(item))
    }

    /// Absent means "every tool" in Hermes' own `matches_tool`, which is what
    /// Uncoil wants — writing `matcher: "*"` would compile as a regex and match
    /// nothing.
    func testUncoilWritesNoMatcher() {
        XCTAssertFalse(
            HermesHookInstaller.renderItem(command: "x").contains { $0.contains("matcher") }
        )
    }

    // MARK: - Removal

    func testUninstallingLeavesTheUsersHooksAndDropsTheBlockWhenEmpty() {
        let mine = """
        hooks:
          pre_tool_call:
            - command: "~/.hermes/agent-hooks/mine.sh"
        """
        var block = HermesHookInstaller.hookBlock(in: installed(into: mine))
        for event in block.events.keys {
            let kept = (block.events[event] ?? []).filter { !HermesHookInstaller.isUncoilItem($0) }
            block.events[event] = kept.isEmpty ? nil : kept
        }
        block.order = block.order.filter { block.events[$0] != nil }
        let body = HermesHookInstaller.renderBody(block)
        let config = HermesYAML.rewriteBlock(
            mine, key: HermesHookInstaller.hooksKey, body: body.isEmpty ? nil : body
        )
        XCTAssertTrue(config.contains("mine.sh"))
        XCTAssertEqual(HermesHookInstaller.status(in: config), .notInstalled)

        // Nothing of the user's left: the block goes rather than lingering empty.
        let emptied = HermesYAML.rewriteBlock(
            installed(into: ""), key: HermesHookInstaller.hooksKey, body: nil
        )
        XCTAssertFalse(emptied.contains("hooks:"))
    }

    /// A comment explains why a hook is there. Keeping the command and dropping
    /// the sentence is not "preserved line for line".
    func testACommentTravelsWithTheHookItIntroduces() {
        let original = """
        hooks:
          # everything below is mine
          pre_tool_call:
            # never let it near rm -rf
            - matcher: "terminal"
              command: "block.sh"
            # and this one formats
            - command: "format.sh"
        """
        let block = HermesHookInstaller.hookBlock(in: original)
        XCTAssertEqual(block.leading, ["  # everything below is mine"])
        let items = block.events["pre_tool_call"] ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].contains { $0.contains("rm -rf") })
        XCTAssertTrue(items[1].contains { $0.contains("formats") })

        let roundTripped = HermesYAML.rewriteBlock(
            original, key: HermesHookInstaller.hooksKey,
            body: HermesHookInstaller.renderBody(block)
        )
        for line in original.components(separatedBy: "\n") where !line.isEmpty {
            XCTAssertTrue(roundTripped.contains(line), "lost line: \(line)")
        }
    }

    // MARK: - Consent

    /// Hermes asks before it runs a hook, once per (event, command), and
    /// remembers the answer here. Uncoil records its own pairs because the user
    /// clicking Connect *is* that answer — but only its own, and never
    /// `hooks_auto_accept`, which would approve every future hook from anyone.
    func testGrantingCoversExactlyUncoilsOwnCommands() {
        let granted = HermesHookInstaller.granting(
            helperPath: helper, into: [:], now: "2026-08-19T00:00:00Z", helperModifiedAt: nil
        )
        let approvals = try! XCTUnwrap(granted["approvals"] as? [[String: Any]])
        XCTAssertEqual(approvals.count, HermesHookInstaller.managedEvents.count)
        XCTAssertNil(granted["hooks_auto_accept"])
        for pair in HermesHookInstaller.managedEvents {
            XCTAssertTrue(
                approvals.contains {
                    $0["event"] as? String == pair.hermes
                        && $0["command"] as? String == HermesHookInstaller.command(
                            helperPath: helper, uncoilEvent: pair.uncoil
                        )
                },
                pair.hermes
            )
        }
    }

    func testGrantingLeavesSomebodyElsesApprovalsAlone() {
        let mine: [String: Any] = [
            "approvals": [
                ["event": "pre_tool_call", "command": "~/.hermes/agent-hooks/mine.sh"],
                ["event": "subagent_stop", "command": "/opt/other/tool.sh"],
            ]
        ]
        let granted = HermesHookInstaller.granting(
            helperPath: helper, into: mine, now: "2026-08-19T00:00:00Z", helperModifiedAt: nil
        )
        let commands = (granted["approvals"] as? [[String: Any]] ?? [])
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("~/.hermes/agent-hooks/mine.sh"))
        XCTAssertTrue(commands.contains("/opt/other/tool.sh"))
    }

    /// A rebuild moves the helper, which changes the command, which is the key
    /// the allowlist matches on. Without this, every rebuild would leave one
    /// more dead grant behind forever.
    func testGrantingReplacesUncoilsOwnStaleEntriesRatherThanAddingToThem() {
        let old = HermesHookInstaller.granting(
            helperPath: "/old/Uncoil.app/Contents/Helpers/uncoil-hook",
            into: [:], now: "2026-08-18T00:00:00Z", helperModifiedAt: nil
        )
        let new = HermesHookInstaller.granting(
            helperPath: helper, into: old, now: "2026-08-19T00:00:00Z", helperModifiedAt: nil
        )
        let approvals = new["approvals"] as? [[String: Any]] ?? []
        XCTAssertEqual(approvals.count, HermesHookInstaller.managedEvents.count)
        XCTAssertFalse(
            approvals.contains { ($0["command"] as? String)?.contains("/old/") == true }
        )
    }
}

// MARK: - The wire shape

/// What the helper hands the reducer, once it has stamped what Hermes leaves out.
final class HermesHookEventTests: XCTestCase {
    private func event(_ object: [String: Any]) -> HookEvent? {
        HookEvent(jsonLine: try! JSONSerialization.data(withJSONObject: object))
    }

    /// Hermes calls it `user_message`; Claude Code calls it `prompt`. Reading
    /// only Claude's key would leave every Hermes session called "new session".
    func testHermesUserMessageIsReadAsThePrompt() {
        let decoded = event([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s-1",
            "cwd": "/tmp/project",
            "user_message": "Add a login screen",
            "model": "anthropic/claude-sonnet-4.6",
        ])
        XCTAssertEqual(decoded?.kind, .userPromptSubmit)
        XCTAssertEqual(decoded?.prompt, "Add a login screen")
        XCTAssertEqual(decoded?.sessionID, "s-1")
        XCTAssertEqual(decoded?.model, "anthropic/claude-sonnet-4.6")
        XCTAssertNotNil(SessionStore.titleCandidate(from: decoded!))
    }

    /// Claude Code's own key still wins where both could appear.
    func testClaudesPromptKeyIsUnaffected() {
        let decoded = event([
            "hook_event_name": "UserPromptSubmit",
            "prompt": "claude's",
            "user_message": "hermes'",
        ])
        XCTAssertEqual(decoded?.prompt, "claude's")
    }

    /// Hermes names the tool the same way, which is the whole reason the
    /// bridge is a stamp rather than a translation layer.
    func testHermesToolPayloadNeedsNoTranslation() {
        let decoded = event([
            "hook_event_name": "PreToolUse",
            "session_id": "s-1",
            "cwd": "/tmp/project",
            "tool_name": "terminal",
            "args": ["command": "echo hello"],
        ])
        XCTAssertEqual(decoded?.kind, .preToolUse)
        XCTAssertEqual(decoded?.toolName, "terminal")
    }
}

extension HookEvent.Kind {
    /// Every event the reducer has a case for, for the coverage assertions.
    static var allNames: [String] {
        [
            "SessionStart", "UserPromptSubmit", "PreToolUse",
            "PostToolUse", "Notification", "Stop", "SessionEnd",
        ]
    }
}
