import SwiftUI

/// The round button beside Uncoil Auto's field: whom a message that names
/// nobody goes to. Closed, it is only the agent's mark; open, it lists the
/// agents this conversation may reach. The choice stays until changed — an
/// `@mention` in one message sends that message elsewhere without moving it.
struct UncoilAutoTargetPicker: View {
    @ObservedObject var conversation: UncoilAutoConversationState
    /// The agents open to this conversation.
    let roster: [UncoilAutoRoster.Entry]
    /// Where a message naming nobody would go right now.
    let resolved: UncoilAutoRoster.Entry?

    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var theme = ThemeStore.shared

    static let size: CGFloat = 28

    var body: some View {
        Menu {
            Section(String(localized: "Send messages to")) {
                ForEach(roster) { entry in
                    Button {
                        conversation.target = entry.handle
                    } label: {
                        if entry.handle == resolved?.handle {
                            Label(title(for: entry), systemImage: "checkmark")
                        } else {
                            Text(title(for: entry))
                        }
                    }
                }
            }
            if settings.quotaOptimization.mode == .preferUnusedQuota, !roster.isEmpty {
                Divider()
                Button("Choose next target automatically") { conversation.target = nil }
            }
            if roster.isEmpty {
                Text("No agent is open to this conversation")
            }
        } label: {
            mark
        }
        // `.button` + `.plain` keeps the label as drawn; the borderless style
        // turns it into a template image and drops the circle.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(resolved.map { String(localized: "Messages without @ go to @\($0.handle). Click to change.") }
              ?? String(localized: "Choose which agent messages without @ go to"))
        .accessibilityIdentifier("chat.composer.target")
        .accessibilityValue(resolved.map { "@\($0.handle)" } ?? "none")
    }

    private var mark: some View {
        ZStack {
            Circle().fill(Theme.panelActive)
            Circle().strokeBorder((resolved?.provider.color ?? Theme.border).opacity(0.55), lineWidth: 1)
            if let resolved {
                ProviderMark(provider: resolved.provider, size: 14)
            } else {
                TablerIcon(name: "sitemap", size: 13, color: Theme.textFaint)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
    }

    private func title(for entry: UncoilAutoRoster.Entry) -> String {
        guard let id = entry.sessionID else {
            return String(localized: "@\(entry.handle) — start a new session")
        }
        return "@\(entry.handle) — \(entry.title) · \(sessionStore.status(of: id).label)"
    }
}
