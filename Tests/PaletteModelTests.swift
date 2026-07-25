import XCTest
@testable import Uncoil

@MainActor
final class PaletteModelTests: XCTestCase {
    private func makeProject(_ name: String, path: String) -> Project {
        Project(name: name, rootPath: path)
    }

    private func baseContext(query: String,
                             projects: [Project],
                             sessions: [SessionRecord] = [],
                             statuses: [UUID: AgentSessionStatus] = [:],
                             currentProjectID: UUID? = nil,
                             currentSessionID: UUID? = nil,
                             files: [URL] = [],
                             artifacts: [URL] = [],
                             projectRoot: String? = nil) -> PaletteContext {
        PaletteContext(
            query: query, projects: projects, sessions: sessions, statuses: statuses,
            currentProjectID: currentProjectID, currentSessionID: currentSessionID,
            files: files, artifacts: artifacts, projectRoot: projectRoot,
            settingsPanes: [("theme", "Tema"), ("accounts", "Hesaplar")])
    }

    private func items(_ groups: [PaletteGroup]) -> [PaletteItem] {
        groups.flatMap(\.items)
    }

    func testCommandsBuiltFromProjects() {
        let project = makeProject("uncoil", path: "/tmp/uncoil")
        let groups = PaletteEngine.compute(baseContext(query: "yeni oturum claude", projects: [project]))
        let titles = items(groups).map(\.title)
        XCTAssertTrue(titles.contains { $0.contains("Yeni Oturum: Claude") && $0.contains("uncoil") })
    }

    func testGlobalCommandsAlwaysPresent() {
        let groups = PaletteEngine.compute(baseContext(query: "", projects: []))
        XCTAssertTrue(items(groups).contains { $0.action == .addProject })
        XCTAssertTrue(items(groups).contains { $0.action == .createTestWorkspace })
        XCTAssertTrue(items(groups).contains { $0.action == .createDebugBundle })
        XCTAssertTrue(items(groups).contains { $0.action == .openExtensions })
    }

    func testSessionsRankedByAttention() {
        let project = makeProject("p", path: "/tmp/p")
        let idle = SessionRecord(projectID: project.id, provider: .claude, accountID: nil, title: "claude: idle one")
        let waiting = SessionRecord(projectID: project.id, provider: .claude, accountID: nil, title: "claude: waiting one")
        let statuses: [UUID: AgentSessionStatus] = [
            idle.id: .idle, waiting.id: .waitingForPermission,
        ]
        // Empty query: sessions sorted by rank, attention first.
        let groups = PaletteEngine.compute(baseContext(
            query: "", projects: [project], sessions: [idle, waiting], statuses: statuses))
        let sessionGroup = groups.first { $0.kind == .session }
        XCTAssertEqual(sessionGroup?.items.first?.action, .focusSession(waiting.id))
    }

    func testCommandsOnlyPrefixHidesProjects() {
        let project = makeProject("uncoil", path: "/tmp/uncoil")
        let groups = PaletteEngine.compute(baseContext(query: ">uncoil", projects: [project]))
        XCTAssertFalse(items(groups).contains { $0.action == .openProject(project.id) })
    }

    func testAskClaudeAppearsForQuestion() {
        let project = makeProject("p", path: "/tmp/p")
        let groups = PaletteEngine.compute(baseContext(
            query: "bu ne işe yarar?", projects: [project], currentProjectID: project.id))
        let ask = items(groups).first { if case .askClaude = $0.action { return true }; return false }
        XCTAssertNotNil(ask)
    }

    func testAskClaudeRequiresCurrentProject() {
        let project = makeProject("p", path: "/tmp/p")
        let groups = PaletteEngine.compute(baseContext(
            query: "soru: nasıl?", projects: [project], currentProjectID: nil))
        XCTAssertFalse(items(groups).contains { if case .askClaude = $0.action { return true }; return false })
    }

    func testFilesOnlyWhenSearching() {
        let project = makeProject("p", path: "/tmp/p")
        let file = URL(fileURLWithPath: "/tmp/p/README.md")
        let empty = PaletteEngine.compute(baseContext(
            query: "", projects: [project], files: [file], projectRoot: "/tmp/p"))
        XCTAssertNil(empty.first { $0.kind == .file })

        let searched = PaletteEngine.compute(baseContext(
            query: "readme", projects: [project], files: [file], projectRoot: "/tmp/p"))
        XCTAssertNotNil(searched.first { $0.kind == .file })
    }

    func testSettingsPanesMatchByTitle() {
        let groups = PaletteEngine.compute(baseContext(query: "tema", projects: []))
        XCTAssertTrue(items(groups).contains { $0.action == .openSettings("theme") })
    }

    // MARK: - File indexer

    func testFileIndexerSkipsExcludedDirs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-index-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("a".utf8).write(to: root.appendingPathComponent("keep.swift"))
        for dir in [".git", "node_modules", ".build", ".uncoil-worktrees", ".hidden"] {
            let d = root.appendingPathComponent(dir)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: d.appendingPathComponent("skip.txt"))
        }
        try Data("h".utf8).write(to: root.appendingPathComponent(".dotfile"))

        let indexed = FileIndexer.index(root: root)
        let names = indexed.map(\.lastPathComponent)
        XCTAssertTrue(names.contains("keep.swift"))
        XCTAssertFalse(names.contains("skip.txt"))
        XCTAssertFalse(names.contains(".dotfile"))
    }

    func testFileIndexerRespectsCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-cap-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<20 {
            try Data("x".utf8).write(to: root.appendingPathComponent("f\(i).txt"))
        }
        XCTAssertEqual(FileIndexer.index(root: root, cap: 5).count, 5)
    }

    // MARK: - Model navigation

    func testModelNavigationWraps() {
        let store = ProjectStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-store-\(UUID().uuidString)"))
        store.addProject(at: URL(fileURLWithPath: "/tmp/nav-project"))
        let sessions = SessionStore()
        let model = PaletteModel()
        model.configure(projectStore: store, sessionStore: sessions,
                        settingsPanes: [("theme", "Tema")])
        model.currentProjectID = store.projects.first?.id
        model.open()
        model.query = "yeni"
        model.recomputeNow()

        let count = model.flatItems.count
        XCTAssertGreaterThan(count, 0)
        model.selectedIndex = 0
        model.move(-1)
        XCTAssertEqual(model.selectedIndex, count - 1)
        model.move(1)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testSelectionClampsWhenResultsShrink() {
        let store = ProjectStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-clamp-\(UUID().uuidString)"))
        store.addProject(at: URL(fileURLWithPath: "/tmp/clamp-project"))
        let sessions = SessionStore()
        let model = PaletteModel()
        model.configure(projectStore: store, sessionStore: sessions,
                        settingsPanes: [("theme", "Tema")])
        model.currentProjectID = store.projects.first?.id
        model.open()

        // Broad query → several results; select a late row.
        model.query = "yeni"
        model.recomputeNow()
        let broadCount = model.flatItems.count
        XCTAssertGreaterThan(broadCount, 1)
        model.selectedIndex = broadCount - 1

        // Narrow query → fewer results; selection must clamp into range.
        model.query = "yeni proje ekle"
        model.recomputeNow()
        let narrowCount = model.flatItems.count
        XCTAssertGreaterThan(narrowCount, 0)
        XCTAssertLessThan(narrowCount, broadCount)
        XCTAssertLessThan(model.selectedIndex, narrowCount)
        XCTAssertGreaterThanOrEqual(model.selectedIndex, 0)
    }

    func testSelectionResetsToZeroWhenNoResults() {
        let store = ProjectStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-empty-\(UUID().uuidString)"))
        store.addProject(at: URL(fileURLWithPath: "/tmp/empty-project"))
        let sessions = SessionStore()
        let model = PaletteModel()
        model.configure(projectStore: store, sessionStore: sessions, settingsPanes: [])
        model.currentProjectID = store.projects.first?.id
        model.open()
        model.query = "yeni"
        model.recomputeNow()
        model.selectedIndex = max(0, model.flatItems.count - 1)

        model.query = "zzzxqqqnomatch"
        model.recomputeNow()
        XCTAssertEqual(model.flatItems.count, 0)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testResultsFullyReplaceWhenQueryChanges() {
        // Guards the contract the view relies on: after a query change the
        // result set is the fresh computation, with no rows lingering from the
        // previous query, and selectedItem resolves into the new set.
        let store = ProjectStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-replace-\(UUID().uuidString)"))
        store.addProject(at: URL(fileURLWithPath: "/tmp/replace-project"))
        let sessions = SessionStore()
        let model = PaletteModel()
        model.configure(projectStore: store, sessionStore: sessions,
                        settingsPanes: [("theme", "Tema")])
        model.currentProjectID = store.projects.first?.id
        model.open()

        model.query = "proje"
        model.recomputeNow()
        let projeTitles = Set(model.flatItems.map(\.title))
        XCTAssertTrue(projeTitles.contains { $0.contains("Yeni Proje Ekle") })

        model.query = "worktree"
        model.recomputeNow()
        let worktreeTitles = model.flatItems.map(\.title)
        // No stale "proje"-only rows survive.
        XCTAssertFalse(worktreeTitles.contains { $0.contains("Yeni Proje Ekle") })
        XCTAssertTrue(worktreeTitles.contains { $0.contains("Worktree") })
        // Selection stays within the new set.
        XCTAssertNotNil(model.selectedItem)
        XCTAssertTrue(model.flatItems.contains { $0.id == model.selectedItem?.id })
    }

    func testExecuteSetsPendingActionAndCloses() {
        let store = ProjectStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-exec-\(UUID().uuidString)"))
        let sessions = SessionStore()
        let model = PaletteModel()
        model.configure(projectStore: store, sessionStore: sessions, settingsPanes: [])
        model.open()
        model.query = "proje ekle"
        model.recomputeNow()
        model.selectedIndex = model.flatItems.firstIndex { $0.action == .addProject } ?? 0
        model.executeSelected()
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(model.pendingAction, .addProject)
    }
}
