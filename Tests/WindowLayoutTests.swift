import XCTest
@testable import Uncoil

/// What a window is asked when it opens, and what it starts on.
final class WindowOpeningTests: XCTestCase {
    private func saved(_ selection: MainSelection?) -> PersistedWindow {
        PersistedWindow(id: UUID(), selection: selection)
    }

    /// An app that questioned the user every launch would be asking something
    /// it already knows the answer to.
    func testARestoredWindowIsNotAskedAnything() {
        let window = saved(.project(UUID()))
        XCTAssertEqual(
            WindowOpening.mode(restoreQueue: [window], openCount: 0), .restored(window)
        )
    }

    /// Even the second and third restored windows: the arrangement is the
    /// answer, and it was already given last time.
    func testEveryRestoredWindowTakesItsSavedStateEvenWithOthersOpen() {
        let first = saved(.project(UUID()))
        let second = saved(nil)
        XCTAssertEqual(
            WindowOpening.mode(restoreQueue: [first, second], openCount: 1), .restored(first)
        )
    }

    /// Nothing to clone, so nothing to ask.
    func testTheVeryFirstWindowIsNotAsked() {
        XCTAssertEqual(WindowOpening.mode(restoreQueue: [], openCount: 0), .first)
    }

    func testAWindowOpenedByHandIsAsked() {
        XCTAssertEqual(WindowOpening.mode(restoreQueue: [], openCount: 1), .asks)
    }
}

/// The two strings a selection is written down as.
final class SelectionCodingTests: XCTestCase {
    func testEveryKindOfSelectionSurvivesTheRoundTrip() {
        let id = UUID()
        for selection: MainSelection in [.project(id), .group(id), .session(id)] {
            let coded = SelectionCoding.encode(selection)
            XCTAssertEqual(
                SelectionCoding.decode(kind: coded.kind, id: coded.id), selection
            )
        }
    }

    func testNothingSelectedDecodesBackToNothing() {
        let coded = SelectionCoding.encode(nil)
        XCTAssertNil(SelectionCoding.decode(kind: coded.kind, id: coded.id))
    }

    /// The keys the single-window build wrote are read as they were, so the
    /// upgrade that made windows plural does not throw a selection away.
    func testTheOldSingleWindowKeysStillDecode() {
        let id = UUID()
        XCTAssertEqual(
            SelectionCoding.decode(kind: "project", id: id.uuidString), .project(id)
        )
    }

    func testGarbageDecodesToNothingRatherThanCrashing() {
        XCTAssertNil(SelectionCoding.decode(kind: "project", id: "not-a-uuid"))
        XCTAssertNil(SelectionCoding.decode(kind: "wat", id: UUID().uuidString))
    }
}

/// What the overlay offers, and what a clone actually opens on.
final class NewWindowOptionsTests: XCTestCase {
    private let mainID = UUID()
    private let otherID = UUID()

    private var windows: [WindowSummary] {
        [
            WindowSummary(id: otherID, title: "uncoil", isMain: false),
            WindowSummary(id: mainID, title: "acme", isMain: true),
        ]
    }

    func testTheMainWindowIsOfferedFirstWhateverOrderItArrivesIn() {
        let options = NewWindowOptions.options(windows: windows)
        XCTAssertEqual(options.first?.choice, .clone(mainID))
    }

    func testEveryOpenWindowIsOfferedPlusAnEmptyOne() {
        let options = NewWindowOptions.options(windows: windows)
        XCTAssertEqual(
            options.map(\.choice), [.clone(mainID), .clone(otherID), .empty]
        )
    }

    /// An empty window is always an answer, even when there is nothing to copy.
    func testTheEmptyWindowIsAlwaysOffered() {
        XCTAssertEqual(NewWindowOptions.options(windows: []).map(\.choice), [.empty])
    }

    func testANamedWindowIsNamedInItsOffer() {
        let options = NewWindowOptions.options(windows: windows)
        XCTAssertTrue(options[1].title.contains("uncoil"), options[1].title)
    }

    func testEveryOfferSaysWhatItDoes() {
        for option in NewWindowOptions.options(windows: windows) {
            XCTAssertFalse(option.title.isEmpty)
            XCTAssertFalse(option.detail.isEmpty)
        }
    }

    // MARK: - What a clone opens on

    /// A clone that opened straight onto "this session is open in another
    /// window" would be a window that arrives broken. The project behind the
    /// session is what someone cloning a window is after anyway.
    func testCloningAWindowShowingASessionOpensOnItsProject() {
        let session = UUID()
        let project = UUID()
        XCTAssertEqual(
            NewWindowOptions.clonedSelection(
                from: .session(session), projectOfSession: { _ in project }
            ),
            .project(project)
        )
    }

    func testCloningASessionWhoseProjectIsGoneOpensOnNothing() {
        XCTAssertNil(
            NewWindowOptions.clonedSelection(
                from: .session(UUID()), projectOfSession: { _ in nil }
            )
        )
    }

    /// Projects and groups are not exclusive, so they are copied as they are.
    func testCloningAProjectOrGroupCopiesItExactly() {
        let id = UUID()
        for selection: MainSelection in [.project(id), .group(id)] {
            XCTAssertEqual(
                NewWindowOptions.clonedSelection(
                    from: selection, projectOfSession: { _ in nil }
                ),
                selection
            )
        }
    }

    func testCloningAnEmptyWindowGivesAnEmptyWindow() {
        XCTAssertNil(
            NewWindowOptions.clonedSelection(from: nil, projectOfSession: { _ in UUID() })
        )
    }
}

/// Which window answers a "show me this" request.
final class SessionRoutingTests: XCTestCase {
    private let key = UUID()
    private let main = UUID()
    private let holder = UUID()

    /// Answering "take me to my agent" with "this session is open in another
    /// window" would be the app refusing its own shortcut.
    func testASessionRequestGoesToTheWindowAlreadyShowingIt() {
        XCTAssertEqual(
            SessionRouting.target(
                for: .session(UUID()), holder: holder, key: key, main: main
            ),
            holder
        )
    }

    func testASessionNobodyHoldsGoesToTheWindowTheUserIsLookingAt() {
        XCTAssertEqual(
            SessionRouting.target(for: .session(UUID()), holder: nil, key: key, main: main),
            key
        )
    }

    /// Projects are not exclusive, so a project request never chases a holder.
    func testAProjectRequestGoesToTheKeyWindow() {
        XCTAssertEqual(
            SessionRouting.target(
                for: .project(UUID()), holder: holder, key: key, main: main
            ),
            key
        )
    }

    /// The menu-bar monitor is used precisely when Uncoil is not frontmost.
    func testWithNoKeyWindowTheRequestGoesToTheMainOne() {
        XCTAssertEqual(
            SessionRouting.target(for: .project(UUID()), holder: nil, key: nil, main: main),
            main
        )
    }

    func testWithNoWindowsAtAllNothingIsRouted() {
        XCTAssertNil(
            SessionRouting.target(for: .project(UUID()), holder: nil, key: nil, main: nil)
        )
    }
}

/// A window's saved frame name.
final class MainWindowFrameSlotTests: XCTestCase {
    /// The first window keeps the name the single-window build used, so an
    /// existing saved frame is not orphaned by this change.
    func testTheFirstWindowKeepsTheOriginalName() {
        XCTAssertEqual(
            MainWindowFrame.autosaveName(slot: 0), MainWindowFrame.autosaveName
        )
        XCTAssertEqual(
            MainWindowFrame.autosaveName(slot: nil), MainWindowFrame.autosaveName
        )
    }

    /// Sharing one name would restore every window onto the same rectangle,
    /// which looks exactly like no new window opening at all.
    func testLaterWindowsGetNamesOfTheirOwn() {
        XCTAssertNotEqual(
            MainWindowFrame.autosaveName(slot: 1), MainWindowFrame.autosaveName(slot: 0)
        )
        XCTAssertNotEqual(
            MainWindowFrame.autosaveName(slot: 2), MainWindowFrame.autosaveName(slot: 1)
        )
    }
}
