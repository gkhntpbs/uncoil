import XCTest
@testable import Uncoil

final class TodoParserTests: XCTestCase {
    private func parse(_ raw: String, path: String = "/p/TODO.md") -> TaskDocument {
        TodoParser.parse(raw, path: path)
    }

    // MARK: - The round-trip guarantee

    func testRenderReproducesTheFileByteForByte() {
        let raw = """
        # Başlık

        Bir paragraf.

        - [ ] açık görev
        - [x] bitmiş görev
          devam satırı
        * [X] yıldız işaretli
        + [ ] artı işaretli

        <!-- bir HTML yorumu -->

        > blockquote

        | a | b |
        |---|---|
        | 1 | 2 |

        ```swift
        - [ ] bu bir görev değil, code block içinde
        ```

        Son satır, newline yok
        """
        let document = parse(raw)
        XCTAssertEqual(document.render(), raw)
    }

    func testRoundTripSurvivesTabsCRLFStyleAndTrailingWhitespace() {
        let raw = "# T\n\n-\t[ ] tab girintili\t\n   \n-  [x]  iki boşluklu  \n\n\n"
        XCTAssertEqual(parse(raw).render(), raw)
    }

    func testRoundTripOfAnEmptyAndAWhitespaceOnlyFile() {
        XCTAssertEqual(parse("").render(), "")
        XCTAssertEqual(parse("\n\n").render(), "\n\n")
        XCTAssertEqual(parse("   ").render(), "   ")
    }

    func testRoundTripOfThisProjectsOwnTodoFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TODO.md")
        let raw = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8))
        let document = parse(raw, path: url.path)
        XCTAssertEqual(
            document.render(), raw,
            "the real TODO.md must survive a parse untouched"
        )
        XCTAssertGreaterThan(document.tasks.count, 500)
    }

    /// The real file is the fixture that matters: every line that looks like a
    /// checkbox outside a fence has to become a task. Counting independently of
    /// the parse is what catches a construct being silently dropped.
    func testNothingInThisProjectsOwnTodoFileIsSilentlyDropped() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TODO.md")
        let raw = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8))
        let document = parse(raw, path: url.path)

        var insideFence = false
        var expected: [String] = []
        for line in raw.components(separatedBy: "\n") {
            if TodoParser.fenceToken(line) != nil {
                insideFence.toggle()
                continue
            }
            guard !insideFence, let checkbox = TodoParser.checkboxComponents(line) else { continue }
            expected.append(checkbox.text)
        }
        XCTAssertEqual(
            document.tasks.map(\.text), expected,
            "every checkbox line outside a fence has to reach the app"
        )
        XCTAssertFalse(
            document.tasks.filter { $0.checkbox.listMarker.hasSuffix(".") }.isEmpty,
            "the numbered list at the end of the file is real work, not prose"
        )
        XCTAssertTrue(
            document.tasks.allSatisfy { !$0.headingPath.isEmpty },
            "no task ends up outside the heading it was written under"
        )
    }

    func testBlocksCoverTheWholeFileWithoutOverlapping() {
        let raw = "# A\n\n- [ ] bir\n  devam\n\n## B\n\n- [x] iki\n"
        let document = parse(raw)
        let sorted = document.blocks.sorted { $0.range.startByte < $1.range.startByte }
        var cursor = 0
        for block in sorted {
            XCTAssertEqual(block.range.startByte, cursor, "gap or overlap before \(block.kind)")
            cursor = block.range.endByte
        }
        XCTAssertEqual(cursor, raw.utf8.count)
    }

    // MARK: - Checkbox recognition

    func testAllSupportedMarkersAndStates() {
        let document = parse("""
        - [ ] tire açık
        - [x] tire bitmiş
        - [X] tire büyük X
        * [ ] yıldız
        + [x] artı
        """)
        XCTAssertEqual(document.tasks.count, 5)
        XCTAssertEqual(document.tasks.map(\.checkbox.listMarker), ["-", "-", "-", "*", "+"])
        XCTAssertEqual(document.tasks.map(\.isDone), [false, true, true, false, true])
        XCTAssertEqual(document.tasks[2].checkbox.markerCharacter, "X")
    }

    func testOrderedListsAreTasksToo() {
        let document = parse("""
        1. [ ] birinci
        2. [x] ikinci
        10) [ ] onuncu
        """)
        XCTAssertEqual(document.tasks.map(\.text), ["birinci", "ikinci", "onuncu"])
        XCTAssertEqual(document.tasks.map(\.checkbox.listMarker), ["1.", "2.", "10)"])
        XCTAssertEqual(document.tasks.map(\.isDone), [false, true, false])
    }

    func testAnOrderedNumberWithoutADelimiterOrACheckboxIsNotATask() {
        let document = parse("""
        1 [ ] nokta yok
        1. sadece numaralı madde
        2026. yılında yapılacaklar
        """)
        XCTAssertTrue(document.tasks.isEmpty)
    }

    func testAlternateMarksAreRecognisedRatherThanDropped() {
        let document = parse("""
        - [-] iptal edildi
        - [~] devam ediyor
        - [/] devam ediyor iki
        """)
        XCTAssertEqual(document.tasks.count, 3)
        XCTAssertEqual(document.tasks.map(\.checkbox.markerCharacter), ["-", "~", "/"])
        XCTAssertEqual(
            document.tasks.map(\.isDone), [true, false, false],
            "iptal edilen iş bitmiştir; devam eden iş hâlâ açıktır"
        )
    }

    func testTabIndentedAndDeeplyNestedTasksAreParsed() {
        let document = parse("- [ ] kök\n\t- [ ] tab çocuk\n\t\t- [ ] tab torun\n        - [ ] sekiz boşluk\n")
        XCTAssertEqual(document.tasks.count, 4)
        XCTAssertEqual(document.tasks.map(\.depth), [0, 1, 2, 2])
        XCTAssertEqual(document.tasks[1].parentID, document.tasks[0].id)
        XCTAssertEqual(document.tasks[2].parentID, document.tasks[1].id)
    }

    func testTasksInsideABlockquoteAreStillTasks() {
        let raw = "> - [ ] alıntı içinde\n> - [x] ikinci\n"
        let document = parse(raw)
        XCTAssertEqual(document.tasks.map(\.text), ["alıntı içinde", "ikinci"])
        XCTAssertEqual(document.tasks[0].checkbox.indent, "> ")
        XCTAssertEqual(document.render(), raw)
    }

    func testAQuotedParagraphDoesNotBecomeThePreviousTasksContinuation() {
        // The blockquote marker adds no indent width on purpose.
        let raw = "- [ ] görev\n\n> alıntı, göreve ait değil\n"
        let document = parse(raw)
        XCTAssertEqual(document.tasks.count, 1)
        XCTAssertFalse(document.tasks[0].rawBlock.contains("alıntı"))
    }

    func testCheckboxesRightUnderAHeadingWithNoBlankLine() {
        let document = parse("## Başlık\n- [ ] hemen altında\n1. [ ] numaralı da\n")
        XCTAssertEqual(document.tasks.count, 2)
        XCTAssertTrue(document.tasks.allSatisfy { $0.headingPath == ["Başlık"] })
    }

    func testCRLFFileParsesAndRoundTrips() {
        let raw = "# A\r\n\r\n- [ ] bir\r\n1. [ ] iki\r\n\t- [x] üç\r\n"
        let document = parse(raw)
        XCTAssertEqual(document.tasks.map(\.text), ["bir", "iki", "üç"])
        XCTAssertEqual(document.render(), raw)
        let bytes = Array(raw.utf8)
        for task in document.tasks {
            let range = task.checkbox.markerRange
            XCTAssertEqual(
                String(decoding: bytes[range.startByte..<range.endByte], as: UTF8.self).count, 3
            )
        }
    }

    func testTogglingKeepsTheAuthorsCapitalisation() {
        let document = parse("- [X] bitmiş\n- [ ] açık\n")
        XCTAssertEqual(document.tasks[0].checkbox.toggledCharacter(), " ")
        XCTAssertEqual(document.tasks[1].checkbox.toggledCharacter(), "x")
        let upper = parse("- [X] bitmiş\n").tasks[0].checkbox
        XCTAssertEqual(upper.toggledCharacter(), " ")
    }

    func testMarkerRangeCoversOnlyTheBrackets() {
        let raw = "  - [ ] görev\n"
        let document = parse(raw)
        let range = document.tasks[0].checkbox.markerRange
        let bytes = Array(raw.utf8)
        XCTAssertEqual(
            String(decoding: bytes[range.startByte..<range.endByte], as: UTF8.self),
            "[ ]"
        )
    }

    func testNonTaskLinesAreNotMistakenForTasks() {
        let document = parse("""
        - normal liste maddesi
        -[ ] boşluk yok
        - [y] geçersiz karakter
        - [ x] fazla karakter
        # [ ] başlıkta checkbox
        metin [ ] ortada
        """)
        XCTAssertTrue(document.tasks.isEmpty)
    }

    func testCheckboxInsideAFencedBlockIsNotATask() {
        let document = parse("""
        - [ ] gerçek görev

        ```md
        - [ ] örnek
        - [x] örnek
        ```

        ~~~
        - [ ] tilde fence içinde
        ~~~
        """)
        XCTAssertEqual(document.tasks.map(\.text), ["gerçek görev"])
    }

    func testAnIndentedFenceStillHidesItsContents() {
        let raw = """
        Örnek:

          ```md
          1. [ ] örnek
          * [ ] örnek
          ```

        - [ ] gerçek görev
        """
        let document = parse(raw)
        XCTAssertEqual(document.tasks.map(\.text), ["gerçek görev"])
        XCTAssertEqual(document.render(), raw)
    }

    // MARK: - Headings and ordering

    func testHeadingChainIsRecorded() {
        let document = parse("""
        # Aşama 1

        ## 1.1 Alt

        - [ ] görev a

        ### 1.1.1 Derin

        - [ ] görev b

        ## 1.2 Başka

        - [ ] görev c
        """)
        XCTAssertEqual(document.tasks[0].headingPath, ["Aşama 1", "1.1 Alt"])
        XCTAssertEqual(document.tasks[1].headingPath, ["Aşama 1", "1.1 Alt", "1.1.1 Derin"])
        XCTAssertEqual(document.tasks[2].headingPath, ["Aşama 1", "1.2 Başka"])
        XCTAssertEqual(document.headings.count, 4)
    }

    func testOrderIsPerHeading() {
        let document = parse("""
        ## A
        - [ ] a1
        - [ ] a2
        ## B
        - [ ] b1
        """)
        XCTAssertEqual(document.tasks.map(\.orderUnderHeading), [0, 1, 0])
    }

    func testSetextHeadingsGiveTheirTasksAHeadingPath() {
        let raw = """
        Üst başlık
        ==========

        - [ ] bir

        Alt başlık
        ----------

        - [ ] iki
        """
        let document = parse(raw)
        XCTAssertEqual(document.headings.map(\.level), [1, 2])
        XCTAssertEqual(document.tasks[0].headingPath, ["Üst başlık"])
        XCTAssertEqual(document.tasks[1].headingPath, ["Üst başlık", "Alt başlık"])
        XCTAssertEqual(document.render(), raw, "the underline is part of the heading block")
    }

    func testAThematicBreakStaysAThematicBreak() {
        // The `---` in this project's own TODO.md separates sections; reading it
        // as a heading would rewrite the whole heading tree.
        let document = parse("# A\n\nParagraf.\n\n---\n\n- [ ] görev\n")
        XCTAssertEqual(document.headings.map(\.text), ["A"])
        XCTAssertEqual(document.tasks[0].headingPath, ["A"])
    }

    func testFrontmatterIsPassthroughAndNotAHeading() {
        let raw = "---\ntitle: Yapılacaklar\n---\n\n# A\n\n- [ ] görev\n"
        let document = parse(raw)
        XCTAssertEqual(document.headings.map(\.text), ["A"])
        XCTAssertEqual(document.tasks.count, 1)
        XCTAssertEqual(document.render(), raw)
    }

    func testHashtagIsNotAHeading() {
        let document = parse("#tag değil başlık\n- [ ] görev\n")
        XCTAssertTrue(document.tasks[0].headingPath.isEmpty)
        XCTAssertTrue(document.headings.isEmpty)
    }

    // MARK: - Nesting and blocks

    func testNestedTasksLinkToTheirParent() {
        let document = parse("""
        - [ ] parent
          - [ ] child bir
          - [x] child iki
            - [ ] torun
        - [ ] kardeş
        """)
        XCTAssertEqual(document.tasks.count, 5)
        let parent = document.tasks[0]
        XCTAssertEqual(parent.depth, 0)
        XCTAssertEqual(parent.childIDs.count, 2)
        XCTAssertTrue(parent.hasChildren)

        XCTAssertEqual(document.tasks[1].parentID, parent.id)
        XCTAssertEqual(document.tasks[1].depth, 1)
        XCTAssertEqual(document.tasks[3].parentID, document.tasks[2].id)
        XCTAssertEqual(document.tasks[3].depth, 2)
        XCTAssertNil(document.tasks[4].parentID)
    }

    func testDescriptionLinesBelongToTheTaskBlock() {
        let raw = """
        - [ ] görev başlığı
          bu açıklama göreve ait.
          bu da.
        - [ ] sonraki
        """
        let document = parse(raw)
        XCTAssertTrue(document.tasks[0].rawBlock.contains("bu açıklama göreve ait."))
        XCTAssertTrue(document.tasks[0].rawBlock.contains("bu da."))
        XCTAssertFalse(document.tasks[0].rawBlock.contains("sonraki"))
        XCTAssertEqual(document.tasks[0].blockRange.lineCount, 3)
    }

    func testTaskWithAnIndentedCodeFenceKeepsItInsideItsBlock() {
        let raw = """
        - [ ] komutu çalıştır
          ```sh
          swift build
          ```
        - [ ] sonraki
        """
        let document = parse(raw)
        XCTAssertTrue(document.tasks[0].rawBlock.contains("swift build"))
        XCTAssertEqual(document.tasks.count, 2)
        XCTAssertEqual(document.render(), raw)
    }

    func testLineRangeIsJustTheFirstLine() {
        let document = parse("- [ ] görev\n  devam\n")
        XCTAssertEqual(document.tasks[0].lineRange.lineCount, 1)
        XCTAssertEqual(document.tasks[0].blockRange.lineCount, 2)
    }

    func testColumnAndLineNumbersAreOneBased() {
        let document = parse("# T\n\n  - [ ] görev\n")
        let task = document.tasks[0]
        XCTAssertEqual(task.lineRange.startLine, 3)
        XCTAssertEqual(task.lineRange.startColumn, 1)
        XCTAssertEqual(task.checkbox.markerRange.startColumn, 5)
    }

    func testMultiByteTextKeepsByteOffsetsConsistent() {
        let raw = "- [ ] Türkçe ğüşçöı görev\n- [x] ikinci\n"
        let document = parse(raw)
        let bytes = Array(raw.utf8)
        for task in document.tasks {
            let slice = String(
                decoding: bytes[task.blockRange.startByte..<task.blockRange.endByte],
                as: UTF8.self
            )
            XCTAssertEqual(slice, task.rawBlock)
        }
        XCTAssertEqual(document.render(), raw)
    }

    // MARK: - Derived views

    func testOpenTasksAndLookupByID() {
        let document = parse("- [ ] a\n- [x] b\n")
        XCTAssertEqual(document.openTasks.map(\.text), ["a"])
        XCTAssertEqual(document.task(id: document.tasks[1].id)?.text, "b")
        XCTAssertNil(document.task(id: "yok"))
    }

    func testTasksUnderAHeading() {
        let document = parse("## A\n- [ ] a1\n## B\n- [ ] b1\n")
        XCTAssertEqual(document.tasks(under: ["A"]).map(\.text), ["a1"])
        XCTAssertEqual(document.tasks(under: ["B"]).map(\.text), ["b1"])
        XCTAssertTrue(document.tasks(under: ["C"]).isEmpty)
    }

    func testContentHashChangesWithContent() {
        XCTAssertEqual(parse("- [ ] a\n").contentHash, parse("- [ ] a\n").contentHash)
        XCTAssertNotEqual(parse("- [ ] a\n").contentHash, parse("- [x] a\n").contentHash)
    }
}

final class TaskFingerprintTests: XCTestCase {
    private func tasks(_ raw: String, path: String = "/p/TODO.md") -> [ProjectTask] {
        TodoParser.parse(raw, path: path).tasks
    }

    func testNormalizationIgnoresCasePunctuationAndSpacing() {
        XCTAssertEqual(
            TaskFingerprint.normalize("Build   the App!"),
            TaskFingerprint.normalize("build the app")
        )
        XCTAssertEqual(TaskFingerprint.normalize("`kod` — ve"), "kod ve")
    }

    func testFingerprintUsesEveryDocumentedInput() {
        let list = tasks("""
        ## Bölüm
        - [ ] önceki
        - [ ] hedef görev
        - [ ] sonraki
        """)
        let target = list[1].fingerprint
        XCTAssertEqual(target.filePath, "/p/TODO.md")
        XCTAssertEqual(target.headingPath, ["Bölüm"])
        XCTAssertEqual(target.normalizedText, "hedef görev")
        XCTAssertFalse(target.rawHash.isEmpty)
        XCTAssertEqual(target.previousText, "önceki")
        XCTAssertEqual(target.nextText, "sonraki")
        XCTAssertEqual(target.orderUnderHeading, 1)
    }

    func testStrongKeyChangesWithTheBlockAndTheFile() {
        let a = tasks("- [ ] görev\n")[0].fingerprint
        let b = tasks("- [ ] görev\n", path: "/other/TODO.md")[0].fingerprint
        let c = tasks("- [ ] görev değişti\n")[0].fingerprint
        XCTAssertNotEqual(a.strongKey, b.strongKey)
        XCTAssertNotEqual(a.strongKey, c.strongKey)
    }

    func testUnchangedTaskResolvesExactly() {
        let before = tasks("## A\n- [ ] bir\n- [ ] iki\n")
        let after = tasks("## A\n- [ ] bir\n- [ ] iki\n")
        XCTAssertEqual(
            TaskRelinker.resolve(before[0].fingerprint, in: after),
            .exact(newTaskID: after[0].id)
        )
    }

    func testCheckingATaskOffStillResolvesIt() {
        let before = tasks("## A\n- [ ] bir\n")
        let after = tasks("## A\n- [x] bir\n")
        let resolution = TaskRelinker.resolve(before[0].fingerprint, in: after)
        XCTAssertEqual(resolution.taskID, after[0].id)
        XCTAssertTrue(resolution.isAutomatic)
        XCTAssertFalse(resolution.needsRelinking)
    }

    func testRewordedTaskInTheSameSlotResolvesPositionally() {
        // Heading and position are the second stage, so a rewording that stayed
        // put is settled before similarity is consulted.
        let before = tasks("## A\n- [ ] veritabanı migration yaz\n")
        let after = tasks("## A\n- [ ] veritabanı migration yaz ve test et\n")
        XCTAssertEqual(
            TaskRelinker.resolve(before[0].fingerprint, in: after),
            .positional(newTaskID: after[0].id)
        )
    }

    func testRewordedTaskThatAlsoMovedResolvesBySimilarity() {
        let before = tasks("## A\n- [ ] veritabanı migration yaz\n")
        let after = tasks("""
        ## A
        - [ ] ikonları yeniden çiz
        - [ ] tema renklerini güncelle
        - [ ] veritabanı migration yaz ve test et
        """)
        guard case .similar(let id, let score) =
            TaskRelinker.resolve(before[0].fingerprint, in: after) else {
            return XCTFail("a task that moved and was reworded should match by similarity")
        }
        XCTAssertEqual(id, after[2].id)
        XCTAssertGreaterThanOrEqual(score, TaskRelinker.similarityFloor)
    }

    func testPositionAloneDoesNotBindAnUnrelatedTask() {
        let before = tasks("## A\n- [ ] veritabanı migration yaz\n")
        let after = tasks("## A\n- [ ] tamamen alakasız bir iş\n")
        XCTAssertEqual(
            TaskRelinker.resolve(before[0].fingerprint, in: after),
            .missing,
            "the same slot is not enough when the wording is unrelated"
        )
    }

    func testCompletelyDifferentTaskIsMissingRatherThanGuessed() {
        let before = tasks("## A\n- [ ] veritabanı migration yaz\n")
        let after = tasks("## A\n- [ ] ikonları yeniden çiz\n")
        let resolution = TaskRelinker.resolve(before[0].fingerprint, in: after)
        XCTAssertEqual(resolution, .missing)
        XCTAssertNil(resolution.taskID)
        XCTAssertTrue(resolution.needsRelinking)
    }

    func testTwoEquallyPlausibleCandidatesAreAmbiguousNotBound() {
        // The old task sat at position 2, which no longer exists, so position
        // cannot settle it and two equally similar candidates remain.
        let before = tasks("""
        ## A
        - [ ] ilk iş
        - [ ] ikinci iş
        - [ ] testleri düzelt
        """)
        let after = tasks("""
        ## A
        - [ ] testleri düzelt bir
        - [ ] testleri düzelt iki
        """)
        guard case .ambiguous(let candidates) =
            TaskRelinker.resolve(before[2].fingerprint, in: after) else {
            return XCTFail("two equally close candidates must stay ambiguous")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func testMissingFileIsMissing() {
        let before = tasks("- [ ] görev\n", path: "/gone/TODO.md")
        XCTAssertEqual(
            TaskRelinker.resolve(before[0].fingerprint, in: tasks("- [ ] görev\n")),
            .missing
        )
    }

    func testResolveAllNeverGivesTwoOldTasksTheSameNewTask() {
        let before = tasks("""
        ## A
        - [ ] testleri düzelt
        - [ ] testleri düzelt tekrar
        """)
        // Both old tasks now look like the single remaining one.
        let after = tasks("## A\n- [ ] testleri düzelt\n")
        let resolutions = TaskRelinker.resolveAll(
            [
                "old-a": before[0].fingerprint,
                "old-b": before[1].fingerprint,
            ],
            in: after
        )
        let bound = resolutions.values.compactMap(\.taskID)
        XCTAssertEqual(Set(bound).count, bound.count, "no new task is claimed twice")
        XCTAssertTrue(
            resolutions.values.contains { $0.needsRelinking },
            "the loser is flagged rather than mis-bound"
        )
    }

    func testResolveAllPrefersExactMatchesOverRewordings() {
        let before = tasks("""
        ## A
        - [ ] tam eşleşen görev
        - [ ] benzeyen görev
        """)
        let after = tasks("""
        ## A
        - [ ] tam eşleşen görev
        - [ ] benzeyen görev biraz değişti
        """)
        let resolutions = TaskRelinker.resolveAll(
            ["a": before[0].fingerprint, "b": before[1].fingerprint], in: after
        )
        XCTAssertEqual(resolutions["a"], .exact(newTaskID: after[0].id))
        XCTAssertEqual(resolutions["b"]?.taskID, after[1].id)
    }

    func testResolutionLabelsExplainThemselves() {
        XCTAssertEqual(TaskRelinker.Resolution.exact(newTaskID: "x").label, "Same task")
        XCTAssertTrue(
            TaskRelinker.Resolution.similar(newTaskID: "x", score: 0.8).label.contains("80")
        )
        XCTAssertTrue(
            TaskRelinker.Resolution.ambiguous(candidates: ["a", "b"]).label.contains("2")
        )
    }
}

final class ProjectTaskModelTests: XCTestCase {
    func testExecutionStatesThatWantTheUser() {
        let attention = ProjectTaskExecutionState.allCases.filter(\.needsAttention)
        XCTAssertEqual(
            Set(attention),
            [.waitingForPermission, .waitingForUser, .testsFailing,
             .reviewRequested, .blocked, .failed]
        )
        XCTAssertFalse(ProjectTaskExecutionState.running.needsAttention)
    }

    func testActiveStatesArePreciselyTheOnesThatBlockASecondClaim() {
        XCTAssertTrue(ProjectTaskExecutionState.running.isActive)
        XCTAssertTrue(ProjectTaskExecutionState.waitingForPermission.isActive)
        XCTAssertFalse(ProjectTaskExecutionState.queued.isActive)
        XCTAssertFalse(ProjectTaskExecutionState.failed.isActive)
        XCTAssertFalse(ProjectTaskExecutionState.completed.isActive)
    }

    func testLeaseExpiryAndOwnership() {
        let session = UUID()
        let start = Date(timeIntervalSince1970: 0)
        let lease = TaskClaimLease(
            taskID: "t", sourcePath: "/p/TODO.md", sessionID: session,
            acquiredAt: start, duration: 60
        )
        XCTAssertFalse(lease.isExpired(at: start.addingTimeInterval(59)))
        XCTAssertTrue(lease.isExpired(at: start.addingTimeInterval(60)))
        XCTAssertTrue(lease.isHeld(by: session, at: start))
        XCTAssertFalse(lease.isHeld(by: UUID(), at: start))
        XCTAssertFalse(lease.isHeld(by: session, at: start.addingTimeInterval(120)))
    }

    func testDefaultBoardColumnsRouteByFileAndExecutionState() {
        let document = TodoParser.parse("- [ ] açık\n- [x] bitmiş\n", path: "/p/TODO.md")
        let open = document.tasks[0]
        let done = document.tasks[1]
        let columns = TaskBoardColumnMapping.defaults

        XCTAssertTrue(columns[0].accepts(task: open, state: .unassigned))
        XCTAssertFalse(
            columns[0].accepts(task: done, state: .unassigned),
            "a checked task never sits in the open column"
        )
        XCTAssertTrue(columns[1].accepts(task: open, state: .running))
        XCTAssertTrue(columns[4].accepts(task: done, state: .completed))
        XCTAssertFalse(columns[4].accepts(task: open, state: .completed))
    }

    func testMetadataDocumentIsVersionedAndDefaultsToNoPortableIDs() {
        let document = ProjectTaskMetadataDocument()
        XCTAssertEqual(document.version, ProjectTaskMetadataDocument.currentVersion)
        XCTAssertFalse(
            document.portableIDsEnabled,
            "Uncoil writes nothing of its own into TODO.md unless asked"
        )
        XCTAssertEqual(document.columns.count, 5)
    }

    func testSourceRangeGeometry() {
        let range = TaskSourceRange(
            startByte: 10, endByte: 20, startLine: 2, endLine: 3, startColumn: 1
        )
        XCTAssertEqual(range.byteCount, 10)
        XCTAssertEqual(range.lineCount, 2)
        XCTAssertTrue(range.contains(byte: 10))
        XCTAssertFalse(range.contains(byte: 20))
        XCTAssertTrue(range.overlaps(TaskSourceRange(
            startByte: 15, endByte: 25, startLine: 3, endLine: 4, startColumn: 1
        )))
        XCTAssertFalse(range.overlaps(TaskSourceRange(
            startByte: 20, endByte: 25, startLine: 3, endLine: 4, startColumn: 1
        )))
    }
}
