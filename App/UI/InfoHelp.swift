import SwiftUI

private struct InfoHelp: ViewModifier {
    let text: String
    @State private var hovering = false
    @State private var showing = false
    @State private var popupHovered = false

    private var helpHeight: CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: 336, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: Theme.TypeScale.small.rawValue)]
        )
        return min(320, max(40, ceil(bounds.height) + 28))
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
                if !Task.isCancelled, hovering, NSEvent.pressedMouseButtons == 0 { showing = true }
            }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ScrollView {
                    Text(text)
                        .font(Theme.ui(.small))
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
                .frame(width: 360, height: helpHeight)
                .environment(\.lineLimit, nil)
                .onHover {
                    popupHovered = $0
                    if !$0, !hovering { showing = false }
                }
            }
            .onChange(of: text) { _, _ in showing = false }
            .onDisappear { showing = false }
    }
}

extension View {
    func infoHelp(_ text: String) -> some View {
        modifier(InfoHelp(text: text))
    }
}
