import SwiftUI
import UniformTypeIdentifiers

/// What the quick-launch strip offers, and in what order.
///
/// The strip was every provider Uncoil knows, in declaration order. That
/// offered agents the user has not installed — buttons that can only fail —
/// and left no room for the order someone actually works in.
struct LauncherSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    /// The row being dragged, so the drop target knows what is landing on it.
    @State private var dragging: AgentProvider?

    private var order: [AgentProvider] {
        settings.launcher.order.isEmpty ? settings.launcherProviders : settings.launcher.order
    }

    private var available: [AgentProvider] {
        AgentProvider.sessionKinds.filter { !order.contains($0) }
    }

    var body: some View {
        SettingsPage(title: String(localized: "Quick Launch")) {
            Section("In the strip") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(order) { provider in
                        row(provider)
                    }
                    // The rule, said out loud rather than only enforced by a
                    // disabled button.
                    Text("Drag to reorder. At least one shortcut stays — without one there is no way to start a session from the project screen.")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }

            if !available.isEmpty {
                Section("Not in the strip") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(available) { provider in
                            addableRow(provider)
                        }
                    }
                }
            }
        }
    }

    private func row(_ provider: AgentProvider) -> some View {
        HStack(spacing: 10) {
            TablerIcon(name: "grip-vertical", size: 12, color: Theme.textFaint)
            ProviderMark(provider: provider, size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
                if provider.isAgent, !settings.installedProviders.contains(provider) {
                    // Kept rather than removed: it is the user's stated choice,
                    // and a CLI can come back. The strip leaves it out until it
                    // does, and this says so.
                    Text("Not installed — hidden from the strip until it is")
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.warn)
                }
            }
            Spacer()
            Button {
                settings.setLauncherOrder(LauncherPrefs.removing(provider, from: order))
            } label: {
                TablerIcon(name: "x", size: 11, color: Theme.textFaint)
            }
            .buttonStyle(.plain)
            .disabled(!LauncherPrefs.canRemove(from: order))
            .help(
                LauncherPrefs.canRemove(from: order)
                    ? String(localized: "Remove from the strip")
                    : String(localized: "The last shortcut cannot be removed")
            )
            .accessibilityIdentifier("launcher.remove.\(provider.rawValue)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            dragging == provider ? Theme.panelActive : Theme.panel,
            in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
        )
        .onDrag {
            dragging = provider
            return NSItemProvider(object: provider.rawValue as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: LauncherDropDelegate(
                target: provider,
                order: order,
                dragging: $dragging,
                apply: { settings.setLauncherOrder($0) }
            )
        )
        .accessibilityIdentifier("launcher.row.\(provider.rawValue)")
    }

    private func addableRow(_ provider: AgentProvider) -> some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider, size: 13)
            Text(provider.displayName)
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button {
                settings.setLauncherOrder(LauncherPrefs.adding(provider, to: order))
            } label: {
                Text("Add")
            }
            .buttonStyle(GhostButtonStyle())
            .accessibilityIdentifier("launcher.add.\(provider.rawValue)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }
}

/// Drops one shortcut onto another's slot.
private struct LauncherDropDelegate: DropDelegate {
    let target: AgentProvider
    let order: [AgentProvider]
    @Binding var dragging: AgentProvider?
    let apply: ([AgentProvider]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let index = order.firstIndex(of: target) else { return }
        apply(LauncherPrefs.moving(dragging, to: index, in: order))
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
