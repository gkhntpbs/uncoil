import AppKit
import SwiftUI

/// Keeps a transcript on its newest line while the reader is there, and
/// leaves it alone once they scroll away.
///
/// SwiftUI on macOS 14 can neither say where a scroll view is nor hold it to
/// its end as content grows without also dragging a reader who scrolled up
/// along with it. The `NSScrollView` underneath can do both, so a probe planted
/// in the content finds it — the same way `ScrollerStyler` does — and watches
/// two things: the clip view's bounds, which move only when the reader
/// scrolls, and the document's frame, which grows as text streams in. Growth
/// follows only if the reader was at the end before it.
@MainActor
final class ChatScrollFollower: ObservableObject {
    /// Whether the reader is at the end. Published only when it flips, so
    /// scrolling costs SwiftUI nothing until the "latest" button must change.
    @Published private(set) var isAtEnd = true

    fileprivate weak var probe: ChatScrollProbe?

    /// Moves to the end and follows again.
    func scrollToEnd() {
        probe?.follow()
    }

    fileprivate func report(atEnd: Bool) {
        if atEnd != isAtEnd { isAtEnd = atEnd }
    }
}

struct ChatScrollProbeView: NSViewRepresentable {
    let follower: ChatScrollFollower

    func makeNSView(context: Context) -> ChatScrollProbe {
        let probe = ChatScrollProbe()
        probe.follower = follower
        follower.probe = probe
        return probe
    }

    func updateNSView(_ nsView: ChatScrollProbe, context: Context) {
        nsView.follower = follower
        follower.probe = nsView
        nsView.attachSoon()
    }
}

final class ChatScrollProbe: NSView {
    /// How close to the end still counts as at it: a line's worth, so a reader
    /// a few points short of the bottom is not treated as having left.
    static let tolerance: CGFloat = 32

    weak var follower: ChatScrollFollower?
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var following = true
    /// Set while the probe moves the view itself, so its own scroll is not
    /// read as the reader leaving.
    private var moving = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachSoon()
    }

    func attachSoon() {
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func attach() {
        guard let found = enclosingScrollView, found !== scrollView else { return }
        detach()
        scrollView = found
        let clip = found.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readerMoved() }
        })
        if let document = found.documentView {
            document.postsFrameChangedNotifications = true
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: document, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.contentChanged() }
            })
        }
        follow()
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Points between the bottom of what is visible and the end of the content.
    private var distanceFromEnd: CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let visible = scrollView.contentView.bounds
        if document.isFlipped {
            return max(0, document.frame.height - visible.maxY)
        }
        return max(0, visible.minY)
    }

    private func readerMoved() {
        guard !moving else { return }
        following = distanceFromEnd <= Self.tolerance
        follower?.report(atEnd: following)
    }

    private func contentChanged() {
        if following { scrollToEnd() }
    }

    func follow() {
        following = true
        follower?.report(atEnd: true)
        scrollToEnd()
    }

    private func scrollToEnd() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let y = document.isFlipped ? max(0, document.frame.height - clip.bounds.height) : 0
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        moving = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        moving = false
    }
}
