import XCTest
@testable import Uncoil

/// Onboarding adds the project the moment the folder is chosen, so choosing
/// again has to take the wrong one back out — a mis-click used to leave a
/// project in the sidebar with no way to change it before finishing setup.
/// What it must never do is delete a project someone has started working in.
final class OnboardingProjectChoiceTests: XCTestCase {
    func testTheWrongFolderIsTakenBackOut() {
        XCTAssertTrue(OnboardingProjectChoice.shouldRemovePrevious(
            previousPath: "/tmp/wrong", newPath: "/tmp/right", previousHasSessions: false
        ))
    }

    func testNothingToRemoveOnTheFirstChoice() {
        XCTAssertFalse(OnboardingProjectChoice.shouldRemovePrevious(
            previousPath: nil, newPath: "/tmp/right", previousHasSessions: false
        ))
    }

    func testChoosingTheSameFolderAgainIsNotARemoval() {
        XCTAssertFalse(OnboardingProjectChoice.shouldRemovePrevious(
            previousPath: "/tmp/same", newPath: "/tmp/same", previousHasSessions: false
        ))
    }

    /// The one that would actually cost the user something.
    func testAProjectWithSessionsIsNeverRemoved() {
        XCTAssertFalse(OnboardingProjectChoice.shouldRemovePrevious(
            previousPath: "/tmp/worked-in", newPath: "/tmp/other", previousHasSessions: true
        ))
    }
}
