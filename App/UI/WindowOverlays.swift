import SwiftUI

/// The question a hand-opened window asks before it becomes anything.
///
/// It covers the window rather than sitting beside it, for the same reason
/// first-run setup does: a half-built window behind the question is the state
/// the question exists to end.
struct NewWindowOverlay: View {
    let options: [NewWindowOption]
    let choose: (NewWindowChoice) -> Void

    var body: some View {
        ZStack {
            Theme.bg.opacity(0.92)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.Space.roomy) {
                VStack(alignment: .leading, spacing: Theme.Space.hair) {
                    Text("New Window")
                        .font(Theme.ui(.title, .medium))
                        .foregroundStyle(Theme.text)
                    Text("What should this window open on?")
                        .font(Theme.ui(.body))
                        .foregroundStyle(Theme.textDim)
                }
                VStack(spacing: Theme.Space.tight) {
                    ForEach(options) { option in
                        Button {
                            choose(option.choice)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(Theme.ui(.body, .medium))
                                    .foregroundStyle(Theme.text)
                                Text(option.detail)
                                    .font(Theme.ui(.small))
                                    .foregroundStyle(Theme.textFaint)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.snug)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                                    .fill(Theme.panel)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("newWindow.\(option.title)")
                    }
                }
            }
            .padding(Theme.Space.section)
            .frame(maxWidth: 420)
        }
        .accessibilityIdentifier("newWindow.overlay")
    }
}

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
