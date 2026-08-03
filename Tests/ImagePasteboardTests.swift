import AppKit
import XCTest
@testable import Uncoil

/// Reading a real `NSPasteboard`.
///
/// The pure tests fix the rules from a list of type identifiers, but a real
/// clipboard puts types on itself that nobody wrote down — writing a string
/// adds several, and an image written as PNG reads back with more than one
/// representation. Those are exactly the cases that decide whether ⌘V is taken
/// from the terminal, so they are checked against the real thing.
final class ImagePasteboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        // A named pasteboard of our own: the tests must not touch what the user
        // has on their clipboard.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("uncoil.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func writeImage() {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
        image.unlockFocus()
        pasteboard.writeObjects([image])
    }

    func testAnImageOnARealPasteboardIsTakenAndWrittenAsPNG() throws {
        writeImage()
        let payloads = try XCTUnwrap(
            SessionImageDropService.pastePayloads(from: pasteboard, mode: .attachFile)
        )
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertTrue(payload.name.hasSuffix(".png"))
        // The bytes have to be a PNG, not TIFF under a `.png` name: that is a
        // file no agent can open.
        let data = try XCTUnwrap(payload.data)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    /// Most of what ⌘V is for. Taking it would be the worst possible
    /// regression, so it is asserted against a real clipboard rather than a
    /// list of types.
    func testTextOnARealPasteboardIsLeftAlone() {
        pasteboard.clearContents()
        pasteboard.setString("just some text", forType: .string)
        XCTAssertNil(
            SessionImageDropService.pastePayloads(from: pasteboard, mode: .attachFile)
        )
    }

    func testAnEmptyPasteboardIsNotOurs() {
        XCTAssertNil(
            SessionImageDropService.pastePayloads(from: pasteboard, mode: .attachFile)
        )
    }

    /// The setting has to reach all the way down: with the agent handling
    /// pastes, an image on the clipboard is still not ours.
    func testTheAgentModeTakesNothingEvenWithAnImageWaiting() {
        writeImage()
        XCTAssertNil(
            SessionImageDropService.pastePayloads(from: pasteboard, mode: .agent)
        )
    }

    /// A copied image file keeps the name it had, and is copied rather than
    /// read into memory.
    func testACopiedImageFileIsTakenByReference() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-paste-\(UUID().uuidString).png")
        try Data("png".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])

        let payloads = try XCTUnwrap(
            SessionImageDropService.pastePayloads(from: pasteboard, mode: .attachFile)
        )
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].name, file.lastPathComponent)
        XCTAssertEqual(payloads[0].source, file)
        XCTAssertNil(payloads[0].data)
    }

    /// A copied `.swift` file is a path someone means to paste as text.
    func testACopiedFileThatIsNotAnImageIsLeftAlone() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-paste-\(UUID().uuidString).swift")
        try Data("code".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertNil(
            SessionImageDropService.pastePayloads(from: pasteboard, mode: .attachFile)
        )
    }
}
