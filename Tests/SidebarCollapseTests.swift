import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Collapsing a project has to remove its session rows from the outline view.
///
/// The chevron only writes to `CollapsedProjects`; everything after that is the
/// coordinator mirroring the store into `NSOutlineView`. That mirror is the part
/// no other test covers, and a mirror that silently does nothing looks exactly
/// like a chevron that does nothing.
@MainActor
final class SidebarCollapseTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCollapsingAProjectHidesItsSessionRows() throws {
        let store = ProjectStore(directory: tempDir)
        store.addProject(at: URL(fileURLWithPath: "/tmp/collapse-demo"))
        let project = store.projects[0]
        store.createSession(
            projectID: project.id, provider: .claude, accountID: nil, title: "claude: bir"
        )
        store.createSession(
            projectID: project.id, provider: .codex, accountID: nil, title: "codex: iki"
        )

        let outlineView = SidebarOutlineView()
        let column = NSTableColumn(identifier: .init("sidebar"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        let coordinator = SidebarOutline.Coordinator()
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.outlineView = outlineView
        outlineView.coordinator = coordinator

        var selection: MainSelection?
        var selectedSessionIDs: Set<UUID> = []
        let environment = SidebarOutline.RowEnvironment(
            projectStore: store,
            sessionStore: SessionStore(),
            settings: SettingsStore(directory: tempDir),
            actions: SidebarRowActions(
                openSessionWindow: { _ in },
                customizeProject: { _ in },
                createGroup: { _ in },
                renameGroup: { _ in },
                confirmDeleteSession: { _ in }
            ),
            isMultiSelecting: false,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            selectedSessionIDs: Binding(
                get: { selectedSessionIDs }, set: { selectedSessionIDs = $0 }
            )
        )

        let collapsed = CollapsedProjects.shared
        collapsed.set(project.id, collapsed: false)
        coordinator.apply(
            environment: environment,
            collapsedProjects: collapsed,
            collapsedGroups: CollapsedGroups.shared
        )
        XCTAssertEqual(
            outlineView.numberOfRows, 3,
            "expanded, the project row and both session rows should be on screen"
        )

        collapsed.set(project.id, collapsed: true)
        coordinator.apply(
            environment: environment,
            collapsedProjects: collapsed,
            collapsedGroups: CollapsedGroups.shared
        )
        XCTAssertEqual(
            outlineView.numberOfRows, 1,
            "collapsed, only the project row should remain"
        )

        collapsed.set(project.id, collapsed: false)
    }
}
