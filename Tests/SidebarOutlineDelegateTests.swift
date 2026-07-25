import AppKit
import XCTest
@testable import Uncoil

/// The sidebar's drag, drop and selection behaviour all hang off *optional*
/// AppKit delegate methods. A misspelled Swift signature for one of those is not
/// a compile error — it is a method that is simply never called, which looks
/// exactly like a feature that quietly does nothing. So the selectors are
/// asserted directly.
@MainActor
final class SidebarOutlineDelegateTests: XCTestCase {
    private func assertResponds(_ coordinator: NSObject, _ selector: String) {
        XCTAssertTrue(
            coordinator.responds(to: Selector(selector)),
            "The sidebar coordinator no longer implements \(selector); whatever it "
                + "drove — a drag, a drop, the pop-out gesture — is now dead code"
        )
    }

    func testCoordinatorImplementsEveryDelegateMethodTheSidebarRelieson() {
        let coordinator = SidebarOutline.Coordinator()
        // Rows and structure.
        assertResponds(coordinator, "outlineView:numberOfChildrenOfItem:")
        assertResponds(coordinator, "outlineView:child:ofItem:")
        assertResponds(coordinator, "outlineView:isItemExpandable:")
        assertResponds(coordinator, "outlineView:viewForTableColumn:item:")
        assertResponds(coordinator, "outlineView:heightOfRowByItem:")
        assertResponds(coordinator, "outlineView:rowViewForItem:")
        assertResponds(coordinator, "outlineView:shouldShowOutlineCellForItem:")
        // Selection.
        assertResponds(coordinator, "outlineView:selectionIndexesForProposedSelection:")
        assertResponds(coordinator, "outlineViewSelectionDidChange:")
        // Dragging, including the drop-outside-to-pop-out gesture.
        assertResponds(coordinator, "outlineView:pasteboardWriterForItem:")
        assertResponds(coordinator, "outlineView:validateDrop:proposedItem:proposedChildIndex:")
        assertResponds(coordinator, "outlineView:acceptDrop:item:childIndex:")
        assertResponds(coordinator, "outlineView:draggingSession:endedAtPoint:operation:")
    }
}
