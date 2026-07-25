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
