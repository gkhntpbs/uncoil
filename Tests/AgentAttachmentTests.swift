import XCTest
@testable import Uncoil

final class AgentAttachmentTests: XCTestCase {
    private let image = AgentAttachment(
        kind: .image,
        url: URL(fileURLWithPath: "/work/.uncoil/dropped/abcd1234/shot.png"),
        promptPath: ".uncoil/dropped/abcd1234/shot.png"
    )
    private let file = AgentAttachment(
        kind: .file,
        url: URL(fileURLWithPath: "/work/.uncoil/dropped/abcd1234/spec.pdf"),
        promptPath: ".uncoil/dropped/abcd1234/spec.pdf"
    )

    func testCodexTurnSendsImagesAsImagesAndLeavesFilesToTheText() {
        let input = CodexEventNormalizer.turnInput(text: "Look", attachments: [image, file])
        XCTAssertEqual(input, .array([
            .object(["type": .string("text"), "text": .string("Look")]),
            .object([
                "type": .string("localImage"),
                "path": .string("/work/.uncoil/dropped/abcd1234/shot.png"),
            ]),
        ]))
    }

    func testCodexUserMessageKeepsItsImages() {
        let item = CodexEventNormalizer.item(.object([
            "id": .string("u1"),
            "type": .string("userMessage"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("Look")]),
                .object(["type": .string("localImage"), "path": .string("/tmp/a.png")]),
                .object(["type": .string("image"), "url": .string("https://example.com/b.png")]),
            ]),
        ]))
        guard case .userMessage(let text, let attachments)? = item?.kind else {
            return XCTFail("expected a user message")
        }
        XCTAssertEqual(text, "Look")
        XCTAssertEqual(attachments.map(\.displayName), ["a.png", "b.png"])
        XCTAssertEqual(attachments.map(\.kind), [.image, .image])

        var renderer = AgentTerminalRenderer()
        XCTAssertTrue(
            renderer.render(.historyLoaded([item!]))?.contains("Look [image: a.png] [image: b.png]") == true
        )
    }

    func testDroppedFileKindFollowsItsName() {
        let directory = URL(fileURLWithPath: "/work/.uncoil/dropped/x")
        let session = UUID()
        let png = SessionImageDropService.attachment(named: "a.png", in: directory, sessionID: session)
        let pdf = SessionImageDropService.attachment(named: "a.pdf", in: directory, sessionID: session)
        XCTAssertEqual(png.kind, .image)
        XCTAssertEqual(pdf.kind, .file)
        XCTAssertEqual(pdf.url.path, "/work/.uncoil/dropped/x/a.pdf")
        XCTAssertEqual(pdf.promptPath, SessionImageDrop.relativePath(fileName: "a.pdf", sessionID: session))
    }

    func testSummaryNamesFilesOrImages() {
        XCTAssertEqual(
            SessionImageDropService.summary([image], verb: .attached),
            "Attached .uncoil/dropped/abcd1234/shot.png."
        )
        XCTAssertEqual(SessionImageDropService.summary([image, image], verb: .pasted), "Pasted 2 images.")
        XCTAssertEqual(SessionImageDropService.summary([image, file], verb: .attached), "Attached 2 files.")
    }

    func testFoldersAreNotAttachable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)

        XCTAssertTrue(SessionImageDrop.isAttachable(file))
        XCTAssertFalse(SessionImageDrop.isAttachable(directory))
        XCTAssertFalse(SessionImageDrop.isAttachable(directory.appendingPathComponent("missing")))
    }
}
