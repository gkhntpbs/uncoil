import AppKit
import SwiftUI

/// Puts the sidebar/palette controls in the title bar, immediately after the
/// traffic lights.
///
/// A SwiftUI overlay cannot do this honestly: it would have to hard-code where
/// the traffic lights are and how tall the title bar is, and both are AppKit's
/// to decide. `NSTitlebarAccessoryViewController` with a leading layout
/// attribute is the mechanism built for exactly this — the system aligns the
/// accessory with the buttons, so there is nothing left to guess.
///
/// They stay there whether the sidebar is open or not: a control that moved
/// house when the sidebar closed is a control you have to look for.
struct TitlebarControls: NSViewRepresentable {
    let onOpenPalette: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenPalette: onOpenPalette)
    }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        context.coordinator.attach(to: probe, retries: 5)
        return probe
    }

    func updateNSView(_ probe: NSView, context: Context) {
        context.coordinator.onOpenPalette = onOpenPalette
        context.coordinator.attach(to: probe, retries: 5)
    }

    static func dismantleNSView(_ probe: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        var onOpenPalette: () -> Void
        private weak var window: NSWindow?
        private var accessory: NSTitlebarAccessoryViewController?
        private var titlebarInteraction: TitlebarInteractionView?
        private var restoreFrame: NSRect?

        init(onOpenPalette: @escaping () -> Void) {
            self.onOpenPalette = onOpenPalette
        }

        /// The probe is not in a window on the first turn of the run loop, so
        /// installation retries the way the frame restorer does.
        func attach(to probe: NSView, retries: Int) {
            DispatchQueue.main.async { [weak self, weak probe] in
                guard let self else { return }
                guard let host = probe?.window else {
                    if retries > 0, let probe { self.attach(to: probe, retries: retries - 1) }
                    return
                }
                window = host
                install(in: host)
            }
        }

        private func install(in host: NSWindow) {
            guard accessory == nil else { return }
            let controller = NSTitlebarAccessoryViewController()
            controller.layoutAttribute = .leading
            let hosting = NSHostingView(
                rootView: WindowControlsCluster(onOpenPalette: { [weak self] in
                    self?.onOpenPalette()
                })
                // Just enough of a gap that the first control does not read as
                // a fourth traffic light.
                .padding(.leading, 2)
            )
            hosting.frame = NSRect(x: 0, y: 0, width: 52, height: 28)
            controller.view = hosting
            host.addTitlebarAccessoryViewController(controller)
            accessory = controller
            if let titlebar = host.standardWindowButton(.closeButton)?.superview {
                let interaction = TitlebarInteractionView(frame: titlebar.bounds)
                interaction.autoresizingMask = [.width, .height]
                interaction.shouldHandle = { [weak self] point in
                    guard let window = self?.window else { return false }
                    return !window.titlebarAccessoryViewControllers.contains(where: {
                        $0.view.convert($0.view.bounds, to: nil).contains(point)
                    }) && ![NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].contains(where: {
                        guard let button = window.standardWindowButton($0), !button.isHidden else { return false }
                        return button.convert(button.bounds, to: nil).contains(point)
                    })
                }
                interaction.onDoubleClick = { [weak self] window in self?.toggleMaximize(window) }
                interaction.setAccessibilityElement(true)
                interaction.setAccessibilityRole(.group)
                interaction.setAccessibilityLabel(String(localized: "Title bar"))
                interaction.setAccessibilityIdentifier("window.titlebar")
                titlebar.addSubview(interaction, positioned: .above, relativeTo: nil)
                titlebarInteraction = interaction
            }
        }

        func toggleMaximize(_ window: NSWindow) {
            guard let screen = window.screen else { return }
            let maximized = screen.visibleFrame
            if let restoreFrame,
               abs(window.frame.minX - maximized.minX) < 1,
               abs(window.frame.minY - maximized.minY) < 1,
               abs(window.frame.width - maximized.width) < 1,
               abs(window.frame.height - maximized.height) < 1 {
                window.setFrame(restoreFrame, display: true)
                self.restoreFrame = nil
            } else {
                restoreFrame = window.frame
                window.setFrame(maximized, display: true)
            }
        }

        func remove() {
            titlebarInteraction?.removeFromSuperview()
            titlebarInteraction = nil
            guard let accessory, let window else { self.accessory = nil; return }
            if let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            self.accessory = nil
        }
    }
}

private final class TitlebarInteractionView: NSView {
    var shouldHandle: (NSPoint) -> Bool = { _ in true }
    var onDoubleClick: ((NSWindow) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)),
              shouldHandle(superview?.convert(point, to: nil) ?? point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2,
           event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
           !window.styleMask.contains(.fullScreen) {
            onDoubleClick?(window)
        } else {
            window.performDrag(with: event)
        }
    }
}
