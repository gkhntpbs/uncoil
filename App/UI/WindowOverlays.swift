import SwiftUI

/// Shown where a terminal would be, when another window holds this session.
///
/// It says which window, and offers both answers: go to the window that has it,
/// or bring it here. Only naming the problem would leave someone with a session
/// they can see in the sidebar and cannot reach from anywhere they can find.
struct SessionElsewhereView: View {
    let sessionTitle: String
    let windowTitle: String
    let reveal: () -> Void
    let moveHere: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.roomy) {
            VStack(spacing: Theme.Space.hair) {
                Text("This session is open in another window")
                    .font(Theme.ui(.large, .medium))
                    .foregroundStyle(Theme.text)
                Text("“\(sessionTitle)” is running in “\(windowTitle)”. A session can only be shown in one window at a time.")
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            HStack(spacing: Theme.Space.tight) {
                Button("Show That Window", action: reveal)
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("sessionElsewhere.reveal")
                Button("Move It Here", action: moveHere)
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("sessionElsewhere.moveHere")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .accessibilityIdentifier("sessionElsewhere.overlay")
    }
}
