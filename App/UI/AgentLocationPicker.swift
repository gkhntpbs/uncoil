import AppKit
import Foundation

/// Pointing Uncoil at an agent CLI it did not find on its own.
///
/// Shared by the two places that offer it — Settings › Agents, which is where
/// agents are managed, and the Extensions window's summary card — so the panel,
/// the wording and the refusal are the same in both. A file chooser that
/// behaved differently on two screens would be a third thing to learn.
@MainActor
enum AgentLocationPicker {
    /// Asks for a location and records it. `completion` is handed a sentence to
    /// show, and whether anything actually changed — a refused location leaves
    /// the row alone, so there is nothing to rescan for.
    ///
    /// Both files and directories are selectable because both are honest
    /// answers to "where is it": people who know the exact launcher pick it, and
    /// people who know the install folder pick that. Hidden files are shown
    /// because the interesting locations — `~/.local/bin`, `~/.nix-profile/bin`
    /// — all begin with a dot, and a panel that cannot reach them is a panel
    /// that cannot solve the problem it was opened for.
    static func choose(
        for agent: ExtensionAgentID,
        settings: SettingsStore,
        completion: @escaping @MainActor (_ message: String, _ changed: Bool) -> Void
    ) {
        let command = agent.cliBinaryName
        let panel = NSOpenPanel()
        panel.title = String(format: String(localized: "Where is %@?"), agent.displayName)
        panel.message = String(
            format: String(localized: "Choose the %1$@ executable, or the folder it is in. Uncoil will look for “%2$@”."),
            agent.displayName, command
        )
        panel.prompt = String(localized: "Use this")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.resolvesAliases = true
        if let current = settings.agentBinaryLocation(forCommand: command) {
            panel.directoryURL = URL(fileURLWithPath: current)
        }

        let handle: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            switch settings.setAgentBinaryLocation(url.path, forCommand: command) {
            case .resolved(let path):
                completion(
                    String(
                        format: String(localized: "%1$@ will be run from %2$@."),
                        agent.displayName, path
                    ),
                    true
                )
            case .nothingExecutableThere:
                // Not stored: a location that finds nothing would leave the row
                // exactly as it was and the user with no idea why.
                completion(
                    String(
                        format: String(localized: "No executable named “%1$@” under %2$@, so nothing was changed."),
                        command, url.path
                    ),
                    false
                )
            }
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { handle(response) }
            }
        } else {
            handle(panel.runModal())
        }
    }

    /// Forgets the chosen location, returning the agent to the usual search.
    static func clear(
        for agent: ExtensionAgentID,
        settings: SettingsStore
    ) -> String {
        settings.clearAgentBinaryLocation(forCommand: agent.cliBinaryName)
        return String(
            format: String(localized: "%@ is back to the usual install locations."),
            agent.displayName
        )
    }

    /// What the row says under an agent whose location the user set.
    ///
    /// A location that has gone away — an ejected disk, a reinstall that moved —
    /// is worth saying out loud: `BinarySearchPath` falls back to the ordinary
    /// search so the agent does not vanish, which means the row would otherwise
    /// look untroubled while the setting quietly does nothing.
    static func detail(for path: String, isReachable: Bool) -> String {
        isReachable
            ? String(format: String(localized: "Looking in %@"), path)
            : String(format: String(localized: "%@ cannot be reached right now."), path)
    }
}
