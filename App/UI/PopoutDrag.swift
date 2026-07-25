import AppKit
import SwiftUI

/// Whether a finished drag means "open this session in its own window".
///
/// A pure decision so the rule is testable without a window server: the drag has
/// to have been refused by every drop target *and* have ended outside the window
/// it started in. Either one alone is not enough — a drag refused inside the
/// window is just a miss, and a drag that ended outside but was accepted (by
/// another app, say) is not ours to reinterpret.
enum PopoutDragDecision {
    static func shouldPopOut(
        operation: NSDragOperation,
        endedAt screenPoint: CGPoint,
        windowFrame: CGRect
    ) -> Bool {
        guard operation == [] else { return false }
        return !windowFrame.insetBy(dx: -8, dy: -8).contains(screenPoint)
    }
}

/// A drag source that reports where its drag ended.
///
/// SwiftUI's `.onDrag` cannot tell us that: it hands over an item provider and
/// says nothing about the outcome. This wraps just enough AppKit to answer "did
/// this drag leave the window?".
struct PopoutDragHandle: NSViewRepresentable {
    /// Payload handed to ordinary drop targets, so dragging onto a group still
    /// works exactly as before.
    let payload: String
    /// Called when the drag ended outside the window with nothing accepting it.
    let onDropOutside: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.payload = payload
        view.onDropOutside = onDropOutside
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.payload = payload
        view.onDropOutside = onDropOutside
    }

    final class DragView: NSView, NSDraggingSource {
        var payload = ""
        var onDropOutside: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: payload as NSString)
            item.setDraggingFrame(bounds, contents: nil)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : .copy
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            guard let frame = window?.frame else { return }
            if PopoutDragDecision.shouldPopOut(
                operation: operation, endedAt: screenPoint, windowFrame: frame
            ) {
                onDropOutside()
            }
        }
    }
}
