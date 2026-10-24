import XCTest
@testable import Uncoil

/// The project picker lists each server or skill once, however many agents
/// declare it, and an agent's tab lists only its own.
final class ExtensionGroupTests: XCTestCase {
    private func mcp(_ id: String, _ name: String) -> ExtensionPackage {
        ExtensionPackage(id: id, kind: .mcpServer, name: name, source: .detectedExternal(path: "/x"))
    }

    private func skill(_ id: String, _ name: String) -> ExtensionPackage {
        ExtensionPackage(id: id, kind: .skill, name: name, source: .detectedExternal(path: "/x"))
    }

    func testTheSameServerFromTwoAgentsIsOneRow() {
        let groups = ExtensionGroup.groups(
            [mcp("claudeCode:figma", "figma"), mcp("codex:figma", "figma"), mcp("codex:linear", "linear")]
        ) { _ in [] }
        XCTAssertEqual(groups.map(\.name), ["figma", "linear"])
        XCTAssertEqual(groups[0].agents, [.claudeCode, .codex])
        XCTAssertEqual(groups[0].allIDs, ["claudeCode:figma", "codex:figma"])
    }

    func testAnAgentsTabListsAndTouchesOnlyItsOwnCopy() {
        let groups = ExtensionGroup.groups(
            [mcp("claudeCode:figma", "figma"), mcp("codex:figma", "figma"), mcp("codex:linear", "linear")]
        ) { _ in [] }
        XCTAssertEqual(groups.filter { $0.isAvailable(to: .claudeCode) }.map(\.name), ["figma"])
        XCTAssertEqual(groups[0].memberIDs(for: .codex), ["codex:figma"])
        XCTAssertEqual(groups[0].memberIDs(for: nil).count, 2)
    }

    func testADuplicatedSkillIsOneRowAndAnUnknownOwnerShowsEverywhere() {
        let groups = ExtensionGroup.groups(
            [skill("managed-review", "review"), skill("local:review", "review")]
        ) { _ in [] }
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isAvailable(to: .codex))
    }

    func testARowWritesOneVerdictToEveryMember() {
        let group = ExtensionGroup.groups(
            [mcp("claudeCode:figma", "figma"), mcp("codex:figma", "figma")]
        ) { _ in [] }[0]
        var selection = ProjectExtensionSelection()
        selection.setAllowed(false, group.memberIDs(for: nil), for: nil)
        XCTAssertFalse(selection.isAllowed(group, for: nil))
        XCTAssertFalse(selection.isAllowed("claudeCode:figma", for: nil))
        XCTAssertFalse(selection.isAllowed("codex:figma", for: nil))
        selection.setAllowed(true, group.memberIDs(for: .codex), for: .codex)
        XCTAssertTrue(selection.isAllowed(group, for: .codex))
        XCTAssertFalse(selection.isAllowed(group, for: .claudeCode))
    }
}

final class ProjectEventNotificationTests: XCTestCase {
    func testAProjectCanSilenceOneEventAndAskForAnother() {
        var prefs = NotificationPrefs()
        let project = UUID()
        var override = NotificationPrefs.ProjectOverride()
        override.setEvent(.turnCompleted, false)
        override.setEvent(.mergeReady, true)
        prefs.perProject[project] = override
        prefs.update(.mergeReady) { $0.enabled = false }

        XCTAssertFalse(prefs.isEnabled(.turnCompleted, project: project))
        XCTAssertTrue(prefs.isEnabled(.turnCompleted, project: UUID()), "other projects follow the app")
        XCTAssertTrue(prefs.isEnabled(.mergeReady, project: project))
        XCTAssertTrue(prefs.isEnabled(.permission, project: project), "unset follows the app")
    }

    func testClearingTheLastEventLeavesNoTable() {
        var override = NotificationPrefs.ProjectOverride()
        override.setEvent(.input, false)
        override.setEvent(.input, nil)
        XCTAssertNil(override.events)
    }
}
