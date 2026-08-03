import XCTest
@testable import Uncoil

/// A CLI agent reads files from disk, through its own sandbox: Codex is
/// confined to its workspace, and Claude Code asks before reading outside the
/// working directory. That is what decides where a dropped image goes and how
/// it is named in the prompt.
final class SessionImageDropTests: XCTestCase {
    // MARK: - What counts as an image

    func testTheUsualImageTypesAreAccepted() {
        for name in ["shot.png", "photo.JPG", "a.jpeg", "b.gif", "c.webp", "d.heic"] {
            XCTAssertTrue(SessionImageDrop.isImage(fileName: name), name)
        }
    }

    func testAnythingElseIsNot() {
        for name in ["notes.md", "Main.swift", "archive.zip", "png", "image.png.txt"] {
            XCTAssertFalse(SessionImageDrop.isImage(fileName: name), name)
        }
    }

    // MARK: - Naming

    /// Two screenshots dropped in a row are both called `Screenshot.png`. The
    /// second replacing the first would lose the image just handed over.
    func testASecondDropDoesNotReplaceTheFirst() {
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let first = SessionImageDrop.uniqueName(for: "Shot.png", at: date, existing: [])
        let second = SessionImageDrop.uniqueName(
            for: "Shot.png", at: date, existing: [first]
        )
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasSuffix(".png"))
    }

    func testTheStampLeadsSoTheDirectoryReadsInOrder() {
        let early = SessionImageDrop.uniqueName(
            for: "a.png", at: Date(timeIntervalSince1970: 1_770_000_000), existing: []
        )
        let late = SessionImageDrop.uniqueName(
            for: "a.png", at: Date(timeIntervalSince1970: 1_780_000_000), existing: []
        )
        XCTAssertLessThan(early, late)
    }

    /// A dropped name is not a path. It comes from whatever was dragged — from
    /// outside — and is used to build one, so the invariant that matters is
    /// that the built path still points inside the drop directory.
    func testASeparatorInTheNameCannotMoveTheFile() {
        let name = SessionImageDrop.uniqueName(
            for: "../../etc/passwd.png", at: Date(), existing: []
        )
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))

        let root = URL(fileURLWithPath: "/w").appendingPathComponent(
            SessionImageDrop.directoryName
        )
        let written = root.appendingPathComponent(name).standardizedFileURL
        XCTAssertEqual(written.deletingLastPathComponent().path, root.standardizedFileURL.path)
    }

    /// The pathological one: a name that is nothing but a parent reference.
    func testANameThatIsOnlyAParentReferenceBecomesAName() {
        let name = SessionImageDrop.uniqueName(for: "..", at: Date(), existing: [])
        XCTAssertFalse(name.hasSuffix(".."))
        XCTAssertFalse(name.contains("/"))
    }

    func testALeadingDotDoesNotHideTheFile() {
        let name = SessionImageDrop.uniqueName(for: ".hidden.png", at: Date(), existing: [])
        XCTAssertFalse(name.hasPrefix("."))
    }

    func testAnEmptyNameStillProducesOne() {
        XCTAssertFalse(
            SessionImageDrop.uniqueName(for: "", at: Date(), existing: []).isEmpty
        )
    }

    // MARK: - The prompt

    /// Relative, and inside the working directory: the one form no agent has to
    /// ask permission for.
    func testThePathIsRelativeToTheWorkingDirectory() {
        let path = SessionImageDrop.relativePath(fileName: "a.png")
        XCTAssertEqual(path, ".uncoil/dropped/a.png")
        XCTAssertFalse(path.hasPrefix("/"))
    }

    /// A path with a space is two arguments to a shell, and a prompt is read
    /// by one.
    func testAPathWithASpaceIsQuoted() {
        XCTAssertEqual(SessionImageDrop.quoted("a b.png"), "\"a b.png\"")
        XCTAssertEqual(SessionImageDrop.quoted("ab.png"), "ab.png")
    }

    /// Paths only. The drop is half a message, and what the image is *about* is
    /// the half the user is still typing — putting words there would be putting
    /// them in their mouth.
    func testTheFragmentIsPathsAndNothingElse() {
        let fragment = SessionImageDrop.promptFragment(
            relativePaths: [".uncoil/dropped/a.png", ".uncoil/dropped/b.png"]
        )
        XCTAssertEqual(fragment, ".uncoil/dropped/a.png .uncoil/dropped/b.png ")
        // Trailing space: the cursor lands ready for the sentence.
        XCTAssertTrue(fragment.hasSuffix(" "))
    }

    func testNothingDroppedIsNothingTyped() {
        XCTAssertEqual(SessionImageDrop.promptFragment(relativePaths: []), "")
    }

    // MARK: - Where it lands

    /// `.uncoil/` already holds run.json and tests.json, which are meant to be
    /// committed. These are not, so they get a subdirectory of their own.
    func testDroppedImagesAreKeptApartFromTheCommittedConfiguration() {
        XCTAssertTrue(SessionImageDrop.directoryName.hasPrefix(".uncoil/"))
        XCTAssertNotEqual(SessionImageDrop.directoryName, ".uncoil")
        XCTAssertFalse(RunConfigFile.relativePath.hasPrefix(SessionImageDrop.directoryName))
        XCTAssertFalse(TestConfigFile.relativePath.hasPrefix(SessionImageDrop.directoryName))
    }

    /// The ignore is self-contained rather than an edit to the project's own
    /// `.gitignore`: that file belongs to the user and is reviewed line by
    /// line.
    func testTheDirectoryIgnoresItself() {
        XCTAssertTrue(SessionImageDrop.ignoreContents.contains("*"))
    }
}
