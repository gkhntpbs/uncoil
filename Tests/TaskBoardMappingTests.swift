import XCTest
@testable import Uncoil

final class TaskBoardMappingTests: XCTestCase {
    private func document(_ raw: String) -> TaskDocument {
        TodoParser.parse(raw, path: "/p/TODO.md")
    }

    // MARK: - Heading recognition

    func testRecognisesEnglishHeadings() {
        let expected: [String: TaskBoardMapping.Lane] = [
            "Backlog": .backlog,
            "Todo": .todo,
            "To Do": .todo,
            "Planned": .todo,
            "In Progress": .inProgress,
            "Doing": .inProgress,
            "Blocked": .blocked,
            "Review": .review,
            "Done": .done,
            "Completed": .done,
        ]
        for (heading, lane) in expected {
            XCTAssertEqual(TaskBoardMapping.lane(for: heading), lane, heading)
        }
    }

    func testRecognisesTurkishHeadings() {
        let expected: [String: TaskBoardMapping.Lane] = [
            "Yapılacak": .todo,
            "Planlanan": .todo,
            "Devam Eden": .inProgress,
            "Üzerinde Çalışılıyor": .inProgress,
            "Engellendi": .blocked,
            "İnceleme": .review,
            "Kontrol": .review,
            "Tamamlandı": .done,
            "Bitenler": .done,
        ]
        for (heading, lane) in expected {
            XCTAssertEqual(TaskBoardMapping.lane(for: heading), lane, heading)
        }
    }

    func testRecognitionIgnoresCaseDiacriticsAndNumbering() {
        XCTAssertEqual(TaskBoardMapping.lane(for: "## 2. IN PROGRESS"), .inProgress)
        XCTAssertEqual(TaskBoardMapping.lane(for: "3) devam eden"), .inProgress)
        XCTAssertEqual(TaskBoardMapping.lane(for: "tamamlandi"), .done)
        XCTAssertEqual(TaskBoardMapping.lane(for: "Aşama 4 — Review"), .review)
    }

    func testUnrecognisedHeadingBecomesItsOwnColumn() {
        XCTAssertEqual(TaskBoardMapping.lane(for: "Runtime daemon"), .custom)
        XCTAssertEqual(TaskBoardMapping.lane(for: ""), .custom)
    }

    func testManualOverrideWins() {
        XCTAssertEqual(
            TaskBoardMapping.lane(
                for: "Runtime daemon", overrides: ["Runtime daemon": .inProgress]
            ),
            .inProgress
        )
        XCTAssertEqual(
            TaskBoardMapping.lane(for: "Done", overrides: ["Done": .backlog]),
            .backlog,
            "an explicit mapping beats recognition"
        )
    }

    // MARK: - Columns

    func testColumnsComeFromTheFilesOwnHeadings() {
        let board = document("""
        ## Todo
        - [ ] a
        ## In Progress
        - [ ] b
        ## Done
        - [x] c
        """)
        let columns = TaskBoardMapping.columns(for: board)
        XCTAssertEqual(columns.map(\.heading), ["Todo", "In Progress", "Done"])
        XCTAssertEqual(columns.map(\.lane), [.todo, .inProgress, .done])
        XCTAssertEqual(columns.map(\.title), ["Yapılacak", "Devam Eden", "Tamamlandı"])
        XCTAssertFalse(columns.contains(where: \.isCustom))
    }

    func testColumnsAreOrderedByLaneNotFileOrder() {
        let board = document("""
        ## Done
        - [x] c
        ## Todo
        - [ ] a
        """)
        XCTAssertEqual(
            TaskBoardMapping.columns(for: board).map(\.lane), [.todo, .done]
        )
    }

    func testUnrecognisedHeadingKeepsItsOwnTitle() {
        let board = document("""
        ## Runtime daemon
        - [ ] a
        ## Done
        - [x] c
        """)
        let columns = TaskBoardMapping.columns(for: board)
        XCTAssertEqual(columns.first { $0.isCustom }?.title, "Runtime daemon")
        XCTAssertEqual(
            columns.last?.heading, "Runtime daemon",
            "a custom column sorts after the known lanes"
        )
    }

    func testTasksWithoutAHeadingStillGetAColumn() {
        let board = document("- [ ] başlıksız görev\n")
        let columns = TaskBoardMapping.columns(for: board)
        XCTAssertEqual(columns.map(\.title), ["Başlıksız"])
        XCTAssertEqual(TaskBoardMapping.tasks(in: columns[0], of: board).map(\.text), ["başlıksız görev"])
    }

    func testUserColumnOrderIsHonouredAndUnlistedColumnsFollow() {
        let board = document("""
        ## Todo
        - [ ] a
        ## In Progress
        - [ ] b
        ## Notlar
        - [ ] c
        """)
        let columns = TaskBoardMapping.columns(
            for: board, columnOrder: ["Notlar", "In Progress"]
        )
        XCTAssertEqual(columns.map(\.heading), ["Notlar", "In Progress", "Todo"])
    }

    func testOnlyTopLevelTasksAreCardsAndNestedOnesStayInside() {
        let board = document("""
        ## Todo
        - [ ] parent
          - [ ] child
        - [ ] sibling
        """)
        let column = TaskBoardMapping.columns(for: board)[0]
        let cards = TaskBoardMapping.tasks(in: column, of: board)
        XCTAssertEqual(cards.map(\.text), ["parent", "sibling"])
        XCTAssertEqual(cards[0].childIDs.count, 1)
    }

    func testAColumnOnlyClaimsItsOwnHeadingsTasks() {
        let board = document("""
        ## Todo
        - [ ] a
        ## Done
        - [x] b
        """)
        let columns = TaskBoardMapping.columns(for: board)
        XCTAssertEqual(
            TaskBoardMapping.tasks(in: columns[0], of: board).map(\.text), ["a"]
        )
        XCTAssertEqual(
            TaskBoardMapping.tasks(in: columns[1], of: board).map(\.text), ["b"]
        )
    }

    func testMappingNeverRewritesHeadings() {
        let raw = "## Devam Eden\n\n- [ ] görev\n"
        let board = document(raw)
        _ = TaskBoardMapping.columns(for: board, overrides: ["Devam Eden": .review])
        XCTAssertEqual(
            board.render(), raw,
            "recognising a heading is a read; the file is untouched"
        )
        XCTAssertEqual(
            TaskBoardMapping.columns(for: board)[0].heading, "Devam Eden",
            "the column keeps the file's own wording"
        )
    }

    func testLanesCarryTheExecutionStatesTheyAccept() {
        XCTAssertTrue(TaskBoardMapping.Lane.inProgress.executionStates.contains(.running))
        XCTAssertTrue(TaskBoardMapping.Lane.blocked.executionStates.contains(.testsFailing))
        XCTAssertTrue(TaskBoardMapping.Lane.review.executionStates.contains(.reviewRequested))
        XCTAssertTrue(TaskBoardMapping.Lane.done.executionStates.contains(.completed))
    }
}

final class TaskFilterTests: XCTestCase {
    private let sessionA = UUID()
    private let sessionB = UUID()

    private var document: TaskDocument {
        TodoParser.parse("""
        ## Runtime
        - [ ] daemon heartbeat ekle
        - [x] log rotation ekle
        ## Arayüz
        - [ ] tema renklerini genişlet
        - [ ] sidebar popout desteği
        """, path: "/p/TODO.md")
    }

    private func assignments(
        _ pairs: [(index: Int, session: UUID, state: ProjectTaskExecutionState)]
    ) -> [String: [TaskSessionAssignment]] {
        let tasks = document.tasks
        var result: [String: [TaskSessionAssignment]] = [:]
        for pair in pairs {
            let task = tasks[pair.index]
            result[task.id, default: []].append(TaskSessionAssignment(
                taskID: task.id, sourcePath: task.sourcePath,
                sessionID: pair.session, role: .implementer, state: pair.state
            ))
        }
        return result
    }

    func testAllIsTheDefaultAndReportsItself() {
        var filter = TaskFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.apply(to: document.tasks).count, 4)
        filter.status = .open
        XCTAssertTrue(filter.isActive)
    }

    func testOpenAndDoneFilters() {
        var filter = TaskFilter()
        filter.status = .open
        XCTAssertEqual(filter.apply(to: document.tasks).count, 3)
        filter.status = .done
        XCTAssertEqual(filter.apply(to: document.tasks).map(\.text), ["log rotation ekle"])
    }

    func testAssignedAndUnassignedFilters() {
        let assigned = assignments([(0, sessionA, .running)])
        var filter = TaskFilter()
        filter.status = .assigned
        XCTAssertEqual(
            filter.apply(to: document.tasks, assignments: assigned).map(\.text),
            ["daemon heartbeat ekle"]
        )
        filter.status = .unassigned
        XCTAssertEqual(filter.apply(to: document.tasks, assignments: assigned).count, 3)
    }

    func testRunningReviewAndBlockedFilters() {
        let mixed = assignments([
            (0, sessionA, .running),
            (2, sessionA, .reviewRequested),
            (3, sessionB, .testsFailing),
        ])
        var filter = TaskFilter()
        filter.status = .running
        XCTAssertEqual(filter.apply(to: document.tasks, assignments: mixed).map(\.text), ["daemon heartbeat ekle"])
        filter.status = .awaitingReview
        XCTAssertEqual(filter.apply(to: document.tasks, assignments: mixed).map(\.text), ["tema renklerini genişlet"])
        filter.status = .blocked
        XCTAssertEqual(filter.apply(to: document.tasks, assignments: mixed).map(\.text), ["sidebar popout desteği"])
    }

    func testHeadingAndSourceFilters() {
        var filter = TaskFilter()
        filter.heading = "Arayüz"
        XCTAssertEqual(filter.apply(to: document.tasks).count, 2)
        filter.heading = nil
        filter.sourcePath = "/other/TODO.md"
        XCTAssertTrue(filter.apply(to: document.tasks).isEmpty)
        filter.sourcePath = "/p/TODO.md"
        XCTAssertEqual(filter.apply(to: document.tasks).count, 4)
    }

    func testSessionFilter() {
        let mixed = assignments([(0, sessionA, .running), (3, sessionB, .running)])
        var filter = TaskFilter()
        filter.sessionID = sessionB
        XCTAssertEqual(
            filter.apply(to: document.tasks, assignments: mixed).map(\.text),
            ["sidebar popout desteği"]
        )
    }

    func testFuzzySearchMatchesTextAndHeadingAndRanks() {
        var filter = TaskFilter()
        filter.query = "heartbeat"
        XCTAssertEqual(filter.apply(to: document.tasks).map(\.text), ["daemon heartbeat ekle"])

        filter.query = "runtime"
        XCTAssertEqual(
            filter.apply(to: document.tasks).count, 2,
            "a heading match counts too"
        )

        filter.query = "tema"
        XCTAssertEqual(filter.apply(to: document.tasks).first?.text, "tema renklerini genişlet")

        filter.query = "zzzz"
        XCTAssertTrue(filter.apply(to: document.tasks).isEmpty)
    }

    func testFiltersCombine() {
        let mixed = assignments([(0, sessionA, .running)])
        var filter = TaskFilter()
        filter.status = .open
        filter.heading = "Runtime"
        filter.query = "daemon"
        XCTAssertEqual(
            filter.apply(to: document.tasks, assignments: mixed).map(\.text),
            ["daemon heartbeat ekle"]
        )
    }
}

final class ProjectTaskViewPreferencesTests: XCTestCase {
    func testDefaultsToDocumentViewAndFileBackedBoard() {
        let preferences = ProjectTaskViewPreferences.default
        XCTAssertEqual(preferences.mode, .document)
        XCTAssertEqual(
            preferences.boardMode, .fileBacked,
            "the file's own headings are the board unless the user says otherwise"
        )
        XCTAssertNil(preferences.selectedSourcePath, "aggregate view by default")
        XCTAssertTrue(preferences.headingOverrides.isEmpty)
    }

    func testPreferencesRoundTripThroughCoding() throws {
        var preferences = ProjectTaskViewPreferences.default
        preferences.mode = .kanban
        preferences.selectedSourcePath = "/p/TODO.md"
        preferences.columnOrder = ["Todo", "Done"]
        preferences.headingOverrides = ["Notlar": .review]
        preferences.filter.status = .open
        preferences.filter.query = "daemon"
        preferences.expandedTaskIDs = ["abc"]

        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(
            try JSONDecoder().decode(ProjectTaskViewPreferences.self, from: data),
            preferences
        )
    }

    func testEveryViewModeHasATitle() {
        for mode in ProjectTaskViewPreferences.Mode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
        }
    }
}
