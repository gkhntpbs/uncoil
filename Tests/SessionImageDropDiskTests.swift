import XCTest
@testable import Uncoil

/// Writing and clearing dropped images, on a real filesystem.
///
/// The pure tests fix the naming and ownership rules, but the promise the user
/// is owed is about files: an image lands where an agent can read it, and a
/// closed session takes its images with it. That is only assertable on disk.
final class SessionImageDropDiskTests: XCTestCase {
    private var workingDirectory: URL!

    override func setUpWithError() throws {
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    private func directory(for sessionID: UUID) -> URL {
        workingDirectory.appendingPathComponent(
            SessionImageDrop.directoryName(for: sessionID)
        )
    }

    @discardableResult
    private func drop(_ name: String, for sessionID: UUID) throws -> String {
        let written = SessionImageDropService.write(
            SessionImageDropService.Payload(name: name, data: Data("png".utf8)),
            into: directory(for: sessionID)
        )
        return try XCTUnwrap(written)
    }

    // MARK: - Writing

    func testAnImageLandsInsideItsSessionsDirectory() throws {
        let session = UUID()
        let name = try drop("shot.png", for: session)
        let path = directory(for: session).appendingPathComponent(name).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// The relative path the prompt gets has to resolve, from the working
    /// directory, to the file that was just written. This is the whole promise.
    func testThePathGivenToTheAgentResolvesToTheFile() throws {
        let session = UUID()
        let name = try drop("shot.png", for: session)
        let relative = SessionImageDrop.relativePath(fileName: name, sessionID: session)
        let resolved = workingDirectory.appendingPathComponent(relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        XCTAssertFalse(relative.hasPrefix("/"))
    }

    /// Copying beats reading a multi-megabyte image into memory and writing it
    /// back out, so a file drop takes that path — and has to produce the same
    /// bytes.
    func testAFileDropIsCopiedByteForByte() throws {
        let source = workingDirectory.appendingPathComponent("source.png")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: source)

        let session = UUID()
        let name = try XCTUnwrap(SessionImageDropService.write(
            SessionImageDropService.Payload(name: "source.png", source: source),
            into: directory(for: session)
        ))
        let written = try Data(
            contentsOf: directory(for: session).appendingPathComponent(name)
        )
        XCTAssertEqual(written, bytes)
    }

    func testTwoDropsOfTheSameNameBothSurvive() throws {
        let session = UUID()
        let first = try drop("Screenshot.png", for: session)
        let second = try drop("Screenshot.png", for: session)
        XCTAssertNotEqual(first, second)
        for name in [first, second] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: directory(for: session).appendingPathComponent(name).path
                ),
                name
            )
        }
    }

    /// The directory ignores itself rather than Uncoil editing the project's
    /// own `.gitignore`.
    func testTheDropRootIgnoresItself() throws {
        try drop("a.png", for: UUID())
        let ignore = workingDirectory
            .appendingPathComponent(SessionImageDrop.directoryName)
            .appendingPathComponent(".gitignore")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignore.path))
    }

    // MARK: - Cleanup

    func testClosingASessionTakesItsImagesWithIt() throws {
        let kept = UUID()
        let closed = UUID()
        try drop("a.png", for: kept)
        try drop("b.png", for: closed)

        SessionImageDropService.removeDirectory(
            sessionID: closed, workingDirectory: workingDirectory.path
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory(for: closed).path)
        )
        // And takes nothing else with it.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory(for: kept).path)
        )
    }

    /// A session removed while Uncoil was not running leaves its directory
    /// behind; nothing else would ever clear it.
    func testTheSweepClearsDirectoriesWithNoSessionBehindThem() throws {
        let live = UUID()
        let gone = UUID()
        try drop("a.png", for: live)
        try drop("b.png", for: gone)

        SessionImageDropService.pruneOrphans(
            workingDirectory: workingDirectory.path, liveSessionIDs: [live]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory(for: live).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(for: gone).path))
    }

    /// The sweep must not take the ignore file with it, or the next drop puts
    /// the directory back into the user's `git status`.
    func testTheSweepLeavesTheIgnoreFileAlone() throws {
        try drop("a.png", for: UUID())
        SessionImageDropService.pruneOrphans(
            workingDirectory: workingDirectory.path, liveSessionIDs: []
        )
        let ignore = workingDirectory
            .appendingPathComponent(SessionImageDrop.directoryName)
            .appendingPathComponent(".gitignore")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignore.path))
    }

    /// A project that has never had a drop has no directory, and the sweep has
    /// to be fine with that rather than creating one.
    func testTheSweepOnAProjectWithNoDropsDoesNothing() {
        SessionImageDropService.pruneOrphans(
            workingDirectory: workingDirectory.path, liveSessionIDs: []
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workingDirectory
                    .appendingPathComponent(SessionImageDrop.directoryName).path
            )
        )
    }
}
