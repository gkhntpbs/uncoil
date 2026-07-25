import XCTest
@testable import Uncoil

final class TodoEditorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilTodoEdit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ raw: String) throws -> (path: String, document: TaskDocument) {
        let url = directory.appendingPathComponent("TODO.md")
        try Data(raw.utf8).write(to: url)
        return (url.path, TodoParser.parse(raw, path: url.path))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Checkbox

    func testTogglingChangesOnlyTheThreeBracketBytes() throws {
        let raw = "# Başlık\n\n  - [ ] görev metni  \n    açıklama\n\nSonrası.\n"
        let (path, document) = try file(raw)
        let patch = TodoEditor.togglePatch(for: document.tasks[0])
        let updated = try TodoEditor.apply([patch], to: raw)

        XCTAssertEqual(
            updated,
            "# Başlık\n\n  - [x] görev metni  \n    açıklama\n\nSonrası.\n"
        )
        XCTAssertEqual(patch.range.byteCount, 3)
        XCTAssertEqual(updated.count, raw.count, "aynı uzunluk: sadece işaret değişti")
        _ = path
    }

    func testTogglingBackKeepsTheAuthorsCapitalLetter() throws {
        let raw = "- [X] bitmiş\n"
        let (_, document) = try file(raw)
        let cleared = try TodoEditor.apply(
            [TodoEditor.togglePatch(for: document.tasks[0])], to: raw
        )
        XCTAssertEqual(cleared, "- [ ] bitmiş\n")

        let reparsed = TodoParser.parse(cleared, path: "/p/TODO.md")
        let reset = try TodoEditor.apply(
            [TodoEditor.togglePatch(for: reparsed.tasks[0])], to: cleared
        )
        XCTAssertEqual(reset, "- [x] bitmiş\n")
    }

    /// Every list style the parser accepts has to be patchable by byte range —
    /// an off-by-one here corrupts the user's file rather than failing loudly.
    func testTogglingEveryListStyleTouchesOnlyThatLine() throws {
        let cases: [(raw: String, expected: String)] = [
            ("* [ ] yıldız\n* [ ] ikinci\n", "* [x] yıldız\n* [ ] ikinci\n"),
            ("+ [ ] artı\n+ [ ] ikinci\n", "+ [x] artı\n+ [ ] ikinci\n"),
            ("1. [ ] bir\n2. [ ] iki\n", "1. [x] bir\n2. [ ] iki\n"),
            ("10) [ ] on\n11) [ ] on bir\n", "10) [x] on\n11) [ ] on bir\n"),
            ("\t- [ ] tab\n\t- [ ] tab iki\n", "\t- [x] tab\n\t- [ ] tab iki\n"),
            ("> - [ ] alıntı\n> - [ ] alıntı iki\n", "> - [x] alıntı\n> - [ ] alıntı iki\n"),
            ("- [~] devam\n- [ ] ikinci\n", "- [x] devam\n- [ ] ikinci\n"),
            ("- [-] iptal\n- [ ] ikinci\n", "- [ ] iptal\n- [ ] ikinci\n"),
        ]
        for (raw, expected) in cases {
            let (_, document) = try file(raw)
            let task = try XCTUnwrap(document.tasks.first)
            let patch = TodoEditor.togglePatch(for: task)
            XCTAssertEqual(patch.range.byteCount, 3, raw.debugDescription)
            XCTAssertEqual(try TodoEditor.apply([patch], to: raw), expected, raw.debugDescription)
        }
    }

    func testRenamingAnOrderedTaskLeavesItsNumberAlone() throws {
        let raw = "1. [ ] eski metin\n2. [ ] sonraki\n"
        let (_, document) = try file(raw)
        let patch = try XCTUnwrap(TodoEditor.renamePatch(for: document.tasks[0], to: "yeni metin"))
        XCTAssertEqual(try TodoEditor.apply([patch], to: raw), "1. [ ] yeni metin\n2. [ ] sonraki\n")
    }

    func testTogglingANestedTaskLeavesTheParentAlone() throws {
        let raw = "- [ ] parent\n  - [ ] child\n- [ ] kardeş\n"
        let (_, document) = try file(raw)
        let child = try XCTUnwrap(document.tasks.first { $0.text == "child" })
        XCTAssertEqual(
            try TodoEditor.apply([TodoEditor.togglePatch(for: child)], to: raw),
            "- [ ] parent\n  - [x] child\n- [ ] kardeş\n"
        )
    }

    // MARK: - Rename

    func testRenameReplacesOnlyTheTaskText() throws {
        let raw = "## A\n\n- [x] eski metin\n  açıklama satırı\n\n- [ ] diğer\n"
        let (_, document) = try file(raw)
        let patch = try XCTUnwrap(
            TodoEditor.renamePatch(for: document.tasks[0], to: "yeni metin")
        )
        XCTAssertEqual(
            try TodoEditor.apply([patch], to: raw),
            "## A\n\n- [x] yeni metin\n  açıklama satırı\n\n- [ ] diğer\n"
        )
    }

    func testRenameKeepsTrailingWhitespaceOutOfTheReplacement() throws {
        let raw = "- [ ] eski   \n"
        let (_, document) = try file(raw)
        let patch = try XCTUnwrap(TodoEditor.renamePatch(for: document.tasks[0], to: "yeni"))
        // Only the text is replaced; the newline survives.
        let updated = try TodoEditor.apply([patch], to: raw)
        XCTAssertTrue(updated.hasSuffix("\n"))
        XCTAssertTrue(updated.contains("- [ ] yeni"))
    }

    func testRenameToTheSameTextOrEmptyIsANoOp() throws {
        let (_, document) = try file("- [ ] aynı\n")
        XCTAssertNil(TodoEditor.renamePatch(for: document.tasks[0], to: "aynı"))
        XCTAssertNil(TodoEditor.renamePatch(for: document.tasks[0], to: "   "))
    }

    // MARK: - Description

    func testDescriptionEditTouchesOnlyTheContinuationLines() throws {
        let raw = "# T\n\n- [ ] görev\n  eski açıklama\n  ikinci satır\n\n- [ ] diğer\n"
        let (_, document) = try file(raw)
        let patch = try XCTUnwrap(
            TodoEditor.descriptionPatch(for: document.tasks[0], to: "yeni açıklama")
        )
        let updated = try TodoEditor.apply([patch], to: raw)
        XCTAssertEqual(updated, "# T\n\n- [ ] görev\n  yeni açıklama\n\n- [ ] diğer\n")
        XCTAssertTrue(updated.contains("- [ ] diğer"), "diğer görev korunuyor")
    }

    func testDescriptionCanBeAddedToATaskThatHadNone() throws {
        let raw = "- [ ] görev\n- [ ] diğer\n"
        let (_, document) = try file(raw)
        let patch = try XCTUnwrap(
            TodoEditor.descriptionPatch(for: document.tasks[0], to: "eklendi")
        )
        XCTAssertEqual(
            try TodoEditor.apply([patch], to: raw),
            "- [ ] görev\n  eklendi\n- [ ] diğer\n"
        )
    }

    // MARK: - Move

    func testMovingATaskCarriesItsChildrenAndDescription() throws {
        let raw = """
        ## Kaynak

        - [ ] taşınacak
          açıklaması
          - [ ] çocuk bir
          - [x] çocuk iki

        - [ ] kalacak

        ## Hedef

        - [ ] hedefte var olan

        """
        let (_, document) = try file(raw)
        let task = try XCTUnwrap(document.tasks.first { $0.text == "taşınacak" })
        let patches = try TodoEditor.movePatches(task: task, to: ["Hedef"], in: document)
        let updated = try TodoEditor.apply(patches, to: raw)

        let reparsed = TodoParser.parse(updated, path: "/p/TODO.md")
        let moved = try XCTUnwrap(reparsed.tasks.first { $0.text == "taşınacak" })
        XCTAssertEqual(moved.headingPath, ["Hedef"])
        XCTAssertTrue(updated.contains("açıklaması"))
        XCTAssertTrue(updated.contains("çocuk bir"))
        XCTAssertTrue(updated.contains("çocuk iki"))
        XCTAssertEqual(
            reparsed.tasks.filter { $0.text == "çocuk bir" }.first?.headingPath,
            ["Hedef"],
            "children move with the parent"
        )
        XCTAssertEqual(
            reparsed.tasks.first { $0.text == "kalacak" }?.headingPath,
            ["Kaynak"]
        )
        XCTAssertTrue(updated.contains("## Kaynak"), "başlıklar korunuyor")
    }

    func testMovingIntoAFileWithNoTrailingNewlineKeepsTheAnchorLine() throws {
        // A file whose last line has no newline is ordinary; pasting the block
        // straight onto that byte offset used to glue it to "- [x] bitmiş" and
        // destroy that task.
        let raw = "## Todo\n\n- [ ] taşınacak\n\n## Done\n\n- [x] bitmiş"
        let (_, document) = try file(raw)
        let task = try XCTUnwrap(document.tasks.first { $0.text == "taşınacak" })
        let updated = try TodoEditor.apply(
            try TodoEditor.movePatches(task: task, to: ["Done"], in: document), to: raw
        )
        XCTAssertTrue(updated.contains("\n- [x] bitmiş\n"), updated)
        let reparsed = TodoParser.parse(updated, path: "/p/TODO.md")
        XCTAssertEqual(reparsed.tasks.count, 2)
        XCTAssertEqual(
            reparsed.tasks.first { $0.text == "taşınacak" }?.headingPath, ["Done"]
        )
        XCTAssertNotNil(reparsed.tasks.first { $0.text == "bitmiş" })
    }

    func testMovingToAnUnknownHeadingIsRefused() throws {
        let (_, document) = try file("## A\n\n- [ ] görev\n")
        XCTAssertThrowsError(
            try TodoEditor.movePatches(task: document.tasks[0], to: ["Yok"], in: document)
        )
    }

    // MARK: - Formatting preservation

    func testCRLFLineEndingsSurviveAToggle() throws {
        let raw = "# T\r\n\r\n- [ ] görev\r\n"
        let (_, document) = try file(raw)
        let updated = try TodoEditor.apply(
            [TodoEditor.togglePatch(for: document.tasks[0])], to: raw
        )
        XCTAssertEqual(updated, "# T\r\n\r\n- [x] görev\r\n")
        XCTAssertTrue(updated.contains("\r\n"), "satır sonu biçimi korunuyor")
    }

    func testAFileWithoutATrailingNewlineKeepsNotHavingOne() throws {
        let raw = "- [ ] görev"
        let (_, document) = try file(raw)
        let updated = try TodoEditor.apply(
            [TodoEditor.togglePatch(for: document.tasks[0])], to: raw
        )
        XCTAssertEqual(updated, "- [x] görev")
        XCTAssertFalse(updated.hasSuffix("\n"))
    }

    func testMultiByteTextIsNotCorrupted() throws {
        let raw = "- [ ] Türkçe ğüşçöı görev 🎯\n  açıklama ç\n"
        let (_, document) = try file(raw)
        let updated = try TodoEditor.apply(
            [TodoEditor.togglePatch(for: document.tasks[0])], to: raw
        )
        XCTAssertEqual(updated, "- [x] Türkçe ğüşçöı görev 🎯\n  açıklama ç\n")
    }

    func testEverythingOutsideThePatchIsByteIdentical() throws {
        let raw = """
        <!-- yorum -->
        # Başlık

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|

        > alıntı

        - [ ] görev

        Son.
        """
        let (_, document) = try file(raw)
        let updated = try TodoEditor.apply(
            [TodoEditor.togglePatch(for: document.tasks[0])], to: raw
        )
        XCTAssertEqual(updated, raw.replacingOccurrences(of: "- [ ] görev", with: "- [x] görev"))
    }

    // MARK: - Patch application rules

    func testOverlappingPatchesAreRefused() throws {
        let raw = "- [ ] görev\n"
        let range = TaskSourceRange(
            startByte: 0, endByte: 8, startLine: 1, endLine: 1, startColumn: 1
        )
        let other = TaskSourceRange(
            startByte: 4, endByte: 10, startLine: 1, endLine: 1, startColumn: 5
        )
        XCTAssertThrowsError(
            try TodoEditor.apply(
                [
                    .init(range: range, replacement: "x", summary: "a"),
                    .init(range: other, replacement: "y", summary: "b"),
                ],
                to: raw
            )
        ) { error in
            XCTAssertEqual(error as? TodoEditor.EditError, .overlappingPatches)
        }
    }

    func testOutOfBoundsPatchIsRefused() {
        XCTAssertThrowsError(
            try TodoEditor.apply(
                [.init(
                    range: TaskSourceRange(
                        startByte: 0, endByte: 999, startLine: 1, endLine: 1, startColumn: 1
                    ),
                    replacement: "x", summary: "a"
                )],
                to: "kısa"
            )
        ) { error in
            XCTAssertEqual(error as? TodoEditor.EditError, .rangeOutOfBounds)
        }
    }

    func testDiffShowsBothSidesAndTheSummary() throws {
        let raw = "- [ ] görev\n"
        let (_, document) = try file(raw)
        let diff = TodoEditor.diff([TodoEditor.togglePatch(for: document.tasks[0])], in: raw)
        XCTAssertTrue(diff.contains("satır 1"))
        XCTAssertTrue(diff.contains("-[ ]"))
        XCTAssertTrue(diff.contains("+[x]"))
        XCTAssertTrue(diff.contains("işaretleniyor"))
    }

    func testEveryEditKindProducesAReadableDiff() throws {
        let raw = """
        ## Kaynak

        - [ ] taşınacak
          açıklaması

        ## Hedef

        - [x] hedefte var olan

        """
        let (_, document) = try file(raw)
        let task = try XCTUnwrap(document.tasks.first { $0.text == "taşınacak" })

        let rename = try XCTUnwrap(TodoEditor.renamePatch(for: task, to: "yeni ad"))
        let renameDiff = TodoEditor.diff([rename], in: raw)
        // The rename patch covers the task's own text only, so that is what the
        // diff shows — not the whole line.
        XCTAssertTrue(renameDiff.contains("-taşınacak"), renameDiff)
        XCTAssertTrue(renameDiff.contains("+yeni ad"), renameDiff)

        let describe = try XCTUnwrap(
            TodoEditor.descriptionPatch(for: task, to: "yeni açıklama")
        )
        let describeDiff = TodoEditor.diff([describe], in: raw)
        XCTAssertTrue(describeDiff.contains("-  açıklaması"), describeDiff)
        XCTAssertTrue(describeDiff.contains("+  yeni açıklama"), describeDiff)

        // A move is two patches: what leaves, and where it lands. Both sides
        // have to show, or the user cannot tell a move from a delete.
        let moveDiff = TodoEditor.diff(
            try TodoEditor.movePatches(task: task, to: ["Hedef"], in: document), in: raw
        )
        XCTAssertTrue(moveDiff.contains("-- [ ] taşınacak"), moveDiff)
        XCTAssertTrue(moveDiff.contains("+- [ ] taşınacak"), moveDiff)
        XCTAssertTrue(moveDiff.contains("Hedef"), moveDiff)

        let block = TodoEditor.blockWithDescendants(of: task, in: document)
        let deleteDiff = TodoEditor.diff(
            [.init(range: block.range, replacement: "", summary: "görev silindi")], in: raw
        )
        XCTAssertTrue(deleteDiff.contains("-- [ ] taşınacak"), deleteDiff)
        XCTAssertTrue(deleteDiff.contains("görev silindi"), deleteDiff)
        XCTAssertFalse(deleteDiff.contains("+"), "a delete adds nothing")
    }

    // MARK: - Safe write

    func testWriteAppliesAtomicallyAndReportsTheNewHash() throws {
        let raw = "- [ ] görev\n"
        let (path, document) = try file(raw)
        let outcome = try TodoEditor.write(
            patches: [TodoEditor.togglePatch(for: document.tasks[0])],
            to: path,
            expectedHash: document.contentHash
        )
        guard case .written(let newHash) = outcome else {
            return XCTFail("expected a plain write, got \(outcome)")
        }
        XCTAssertNotEqual(newHash, document.contentHash)
        XCTAssertEqual(try read(path), "- [x] görev\n")
    }

    func testWriteRefusesWhenTheFileChangedAndNoRebuildIsOffered() throws {
        let (path, document) = try file("- [ ] görev\n")
        try Data("- [ ] görev\n- [ ] agent ekledi\n".utf8)
            .write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(
            try TodoEditor.write(
                patches: [TodoEditor.togglePatch(for: document.tasks[0])],
                to: path,
                expectedHash: document.contentHash
            )
        ) { error in
            XCTAssertEqual(error as? TodoEditor.EditError, .staleFile(path: path))
        }
        XCTAssertEqual(
            try read(path), "- [ ] görev\n- [ ] agent ekledi\n",
            "the agent's line is not overwritten"
        )
    }

    func testAnUnrelatedChangeElsewhereIsRecomputedNotRejected() throws {
        let (path, document) = try file("## A\n\n- [ ] görev\n")
        let task = document.tasks[0]
        // An agent appended a task elsewhere; our task's block is untouched.
        try Data("## A\n\n- [ ] görev\n\n## B\n\n- [ ] agent ekledi\n".utf8)
            .write(to: URL(fileURLWithPath: path))

        let outcome = try TodoEditor.write(
            patches: [TodoEditor.togglePatch(for: task)],
            to: path,
            expectedHash: document.contentHash,
            rebuild: TodoEditor.rebuilder(for: task) { [TodoEditor.togglePatch(for: $0)] }
        )
        guard case .recomputed = outcome else {
            return XCTFail("expected the edit to be recomputed, got \(outcome)")
        }
        let final = try read(path)
        XCTAssertTrue(final.contains("- [x] görev"))
        XCTAssertTrue(final.contains("- [ ] agent ekledi"), "agent'ın eklediği korunuyor")
    }

    func testAChangeInTheEditedBlockBecomesAConflictForTheUser() throws {
        let (path, document) = try file("## A\n\n- [ ] görev\n")
        let task = document.tasks[0]
        // The very task being edited was reworded by someone else.
        try Data("## A\n\n- [ ] görev başka biçimde yazıldı\n".utf8)
            .write(to: URL(fileURLWithPath: path))

        let outcome = try TodoEditor.write(
            patches: [TodoEditor.togglePatch(for: task)],
            to: path,
            expectedHash: document.contentHash,
            rebuild: TodoEditor.rebuilder(for: task) { [TodoEditor.togglePatch(for: $0)] }
        )
        XCTAssertFalse(outcome.didWrite)
        guard case .conflict = outcome else {
            return XCTFail("expected a conflict, got \(outcome)")
        }
        XCTAssertEqual(
            try read(path), "## A\n\n- [ ] görev başka biçimde yazıldı\n",
            "nothing is written while a conflict is unresolved"
        )
    }

    func testDeletedTaskCannotBeRebuiltAndIsReportedStale() throws {
        let (path, document) = try file("## A\n\n- [ ] görev\n")
        let task = document.tasks[0]
        try Data("## A\n\n- [ ] tamamen farklı bir iş\n".utf8)
            .write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(
            try TodoEditor.write(
                patches: [TodoEditor.togglePatch(for: task)],
                to: path,
                expectedHash: document.contentHash,
                rebuild: TodoEditor.rebuilder(for: task) { [TodoEditor.togglePatch(for: $0)] }
            )
        )
    }

    func testWriteCanKeepAShortLivedBackup() throws {
        let (path, document) = try file("- [ ] görev\n")
        let backups = directory.appendingPathComponent("backups", isDirectory: true)
        _ = try TodoEditor.write(
            patches: [TodoEditor.togglePatch(for: document.tasks[0])],
            to: path,
            expectedHash: document.contentHash,
            backupDirectory: backups
        )
        let backup = backups.appendingPathComponent("TODO.md.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "- [ ] görev\n")
    }

    func testWritingNothingIsHarmless() throws {
        let (path, document) = try file("- [ ] görev\n")
        let outcome = try TodoEditor.write(
            patches: [], to: path, expectedHash: document.contentHash
        )
        XCTAssertTrue(outcome.didWrite)
        XCTAssertEqual(try read(path), "- [ ] görev\n")
    }

    func testRoundTripAfterAnEditStillReproducesTheFile() throws {
        let raw = "# T\n\n- [ ] a\n  açıklama\n\n- [x] b\n"
        let (_, document) = try file(raw)
        let updated = try TodoEditor.apply(
            [TodoEditor.togglePatch(for: document.tasks[0])], to: raw
        )
        XCTAssertEqual(
            TodoParser.parse(updated, path: "/p/TODO.md").render(),
            updated,
            "the edited file still parses losslessly"
        )
    }
}
