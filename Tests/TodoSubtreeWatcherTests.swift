import XCTest
import CoreServices
@testable import Uncoil

/// Which filesystem events are worth a rescan. Pure, so the rule is testable
/// without waiting on the kernel.
final class TodoSubtreeWatcherRuleTests: XCTestCase {
    private let fileFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
    private let createdDirectory = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated
    )
    private let modifiedDirectory = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified
    )

    func testATaskFileAnywhereCounts() {
        XCTAssertTrue(TodoSubtreeWatcher.isInteresting(
            path: "/p/packages/inner/TODO.md", flags: fileFlags))
        XCTAssertTrue(TodoSubtreeWatcher.isInteresting(path: "/p/todo.md", flags: fileFlags))
    }

    func testAnOrdinaryFileDoesNot() {
        XCTAssertFalse(TodoSubtreeWatcher.isInteresting(
            path: "/p/App/Core/Models.swift", flags: fileFlags))
    }

    /// A build writes thousands of files a second and none of them can change
    /// what the project's tasks are.
    func testNothingInsideADependencyTreeOrBuildCacheCounts() {
        XCTAssertFalse(TodoSubtreeWatcher.isInteresting(
            path: "/p/node_modules/left-pad/TODO.md", flags: fileFlags))
        XCTAssertFalse(TodoSubtreeWatcher.isInteresting(
            path: "/p/.build-cache/DerivedData/x/TODO.md", flags: fileFlags))
        XCTAssertFalse(TodoSubtreeWatcher.isInteresting(
            path: "/p/.git/objects", flags: createdDirectory))
    }

    /// A folder dropped into the project is named by the event; whatever it
    /// already contained is not.
    func testADirectoryAppearingCountsButATouchedOneDoesNot() {
        XCTAssertTrue(TodoSubtreeWatcher.isInteresting(
            path: "/p/packages/inner", flags: createdDirectory))
        XCTAssertFalse(TodoSubtreeWatcher.isInteresting(
            path: "/p/packages/inner", flags: modifiedDirectory))
    }
}
