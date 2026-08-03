import SwiftUI

/// The app's two filled button styles. They lived in `FolderPicker.swift`,
/// which owned nothing else about them, and went missing the moment that
/// picker was replaced by the system panel.

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration)
    }

    private struct Rendered: View {
        let configuration: Configuration
        @ObservedObject private var theme = ThemeStore.shared
        @State private var hovering = false

        init(configuration: Configuration) { self.configuration = configuration }

        private var fill: Color {
            if configuration.isPressed { return Theme.highlightActive }
            return hovering ? Theme.highlightHover : Theme.highlight
        }

        var body: some View {
            configuration.label
                .font(Theme.mono(.body, .semibold))
                .foregroundStyle(Theme.textOnHighlight)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .buttonFeedback(isPressed: configuration.isPressed, hovering: $hovering)
        }
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration)
    }

    private struct Rendered: View {
        let configuration: Configuration
        @ObservedObject private var theme = ThemeStore.shared
        @State private var hovering = false

        init(configuration: Configuration) { self.configuration = configuration }

        private var fill: Color {
            if configuration.isPressed { return Theme.panelActive }
            return hovering ? Theme.panelHover : Theme.panel
        }

        var body: some View {
            configuration.label
                .font(Theme.mono(.body))
                // A ghost button that only ever dims its own text is hard to
                // tell from a label; the text lifts to full strength under the
                // pointer, the way the fill does.
                .foregroundStyle(hovering ? Theme.text : Theme.textDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .strokeBorder(
                            hovering ? Theme.highlightBorder : Theme.border, lineWidth: 1
                        )
                )
                .buttonFeedback(isPressed: configuration.isPressed, hovering: $hovering)
        }
    }
}
