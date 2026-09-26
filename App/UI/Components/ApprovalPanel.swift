import SwiftUI

/// An agent asking before it acts, and the answers it will take.
///
/// One panel for every provider and every place the question is asked: above
/// a session's terminal, and inline in its chat where the request was made.
/// It knows the decisions by their common names — `decline`,
/// `acceptForSession`, `accept` — and offers only the ones the agent listed.
struct ApprovalPanel: View {
    let title: String
    let detail: String?
    let decisions: [String]
    let respond: (String) -> Void
    /// Prefix for the accessibility identifiers, so UI tests can tell the
    /// banner above a terminal from the one in a chat.
    var identifier = "session.codexApproval"

    var body: some View {
        HStack(spacing: 12) {
            TablerIcon(name: "shield-lock", size: 16, color: Theme.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.mono(.body, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                }
            }
            Spacer()
            if decisions.contains("decline") {
                Button("Deny") { respond("decline") }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("\(identifier).decline")
            }
            if decisions.contains("acceptForSession") {
                Button("For the Session") { respond("acceptForSession") }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("\(identifier).session")
            }
            if decisions.contains("accept") {
                Button("Allow Once") { respond("accept") }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("\(identifier).accept")
            }
        }
        .padding(12)
        .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(Theme.warn.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
