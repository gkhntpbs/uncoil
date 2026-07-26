import SwiftUI

/// Makes a theme change reach every view, not only the ones that happened to
/// redraw for another reason.
///
/// `Theme.panel` and friends are static reads of the live palette, so a view
/// that SwiftUI has no reason to re-evaluate keeps painting yesterday's colours.
/// That is what left the session header and the terminal dark inside a light
/// window while the sidebar — which rebuilds constantly — had already switched.
///
/// Identity keyed on the palette rebuilds the window's content when, and only
/// when, the colours actually change. Terminals survive it: they are owned by
/// `TerminalRegistry`, not by the view, so scrollback and running processes are
/// untouched.
struct ThemedWindow<Content: View>: View {
    @ObservedObject private var theme = ThemeStore.shared
    @ViewBuilder var content: Content

    var body: some View {
        content
            .id(theme.palette)
            .preferredColorScheme(theme.palette.isLight ? .light : .dark)
            .environmentObject(theme)
            .sweepScrollers()
    }
}
