import SwiftUI

private struct InfoHelp: ViewModifier {
    let text: String
    @State private var hovering = false
    @State private var showing = false
    @State private var popupHovered = false
    @State private var id = UUID()
    @ObservedObject private var popups = TransientPopups.shared

    /// Short help is laid out at its natural height — no scroll view, so no
    /// scroll bar from a measurement a pixel short. Only text that would not
    /// fit scrolls.
    private var needsScroll: Bool { helpHeight >= Self.maxHeight }
    private static let maxHeight: CGFloat = 320

    private var helpHeight: CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: 336, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: Theme.TypeScale.small.rawValue)]
        )
        return min(Self.maxHeight, max(40, ceil(bounds.height) + 28))
    }

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .onHover { hovering = $0 }
            .task(id: hovering) {
                guard hovering else {
                    try? await Task.sleep(for: .milliseconds(200))
                    if !Task.isCancelled, !popupHovered { showing = false }
                    return
                }
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled, hovering, NSEvent.pressedMouseButtons == 0,
                   popups.claimHelp(id) {
                    showing = true
                }
            }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Group {
                    if needsScroll {
                        ScrollView { helpText }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(width: 360, height: Self.maxHeight)
                            .sweepScrollers()
                    } else {
                        helpText.frame(width: 360)
                    }
                }
                .environment(\.lineLimit, nil)
                .onHover {
                    popupHovered = $0
                    if !$0, !hovering { showing = false }
                }
            }
            .onChange(of: text) { _, _ in showing = false }
            // Another bubble claimed the slot, or a menu/sheet/palette opened.
            .onChange(of: popups.activeHelp) { _, active in
                if active != id, showing { showing = false }
            }
            .onChange(of: showing) { _, now in if !now { popups.releaseHelp(id) } }
            .dismissWithTransientPopups($showing)
            .onDisappear { showing = false; popups.releaseHelp(id) }
    }

    private var helpText: some View {
        Text(text)
            .font(Theme.ui(.small))
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }
}

extension View {
    func infoHelp(_ text: String) -> some View {
        modifier(InfoHelp(text: text))
    }
}
