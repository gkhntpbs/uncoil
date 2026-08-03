import AppKit
import SwiftUI

/// Settings → Uncoil MCP: what the control plane is, and whether it is working.
///
/// There is nothing to install here, and that is the first thing the page has
/// to say. Uncoil registers its own MCP server per session as the agent
/// launches — Claude gets a `--mcp-config` written for that session, Codex gets
/// the equivalent `-c` overrides — so a user looking for an install button is
/// looking for something that would be wrong to add. What they actually need
/// when the tools are missing is the diagnosis: is the server accepting
/// connections, is the helper binary in the bundle, and does this provider get
/// wired at all.
struct McpSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var status = McpStatusStore.shared

    private var helperPath: String? {
        let binary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/uncoil-mcp")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary.path : nil
    }

    var body: some View {
        SettingsPage(title: String(localized: "Uncoil MCP")) {
            Section("Status") {
                AdaptiveRow {
                    SettingsLabel(
                        title: String(localized: "Control plane"),
                        detail: String(localized: "The socket the agents' MCP helpers connect back to. It starts with Uncoil and needs no setup."),
                        symbol: "point.3.connected.trianglepath.dotted"
                    )
                } control: {
                    SettingsStatusLine(
                        level: status.isServing ? .ok : .warning,
                        text: status.isServing
                            ? String(localized: "serving")
                            : String(localized: "not serving")
                    )
                }

                AdaptiveRow {
                    SettingsLabel(
                        title: String(localized: "Helper binary"),
                        detail: helperPath ?? String(localized: "uncoil-mcp is missing from the app bundle. Sessions will start, and the uncoil tools will not be there."),
                        symbol: "shippingbox"
                    )
                } control: {
                    SettingsStatusLine(
                        level: helperPath == nil ? .warning : .ok,
                        text: helperPath == nil
                            ? String(localized: "missing")
                            : String(localized: "bundled")
                    )
                }

                SettingsNote(String(
                    localized: "Nothing is installed into your agents' own configuration: the server is registered for one session, as that session launches, and goes away with it."
                ))
            }

            Section("Per Agent") {
                ForEach(AgentProvider.agents) { provider in
                    AdaptiveRow {
                        SettingsLabel(
                            title: provider.displayName,
                            detail: provider.wiresControlPlane
                                ? String(localized: "Registered for every session Uncoil starts.")
                                : String(localized: "No verified way to register a server per session yet, so Uncoil does not claim one: its sessions run without the uncoil tools rather than advertising tools that are not there.")
                        )
                    } control: {
                        SettingsStatusLine(
                            level: provider.wiresControlPlane ? .ok : .warning,
                            text: provider.wiresControlPlane
                                ? String(localized: "wired")
                                : String(localized: "not wired")
                        )
                    }
                }
            }

            Section("Tools") {
                SettingsNote(String(
                    localized: "Eight tools, each taking an action. Every one of them answers {\"action\":\"help\"} with its own documentation, which is the authoritative list — this page does not repeat it."
                ))
                AdaptiveRow {
                    SettingsLabel(
                        title: String(localized: "uncoil_projects · uncoil_sessions · uncoil_artifacts · uncoil_tasks"),
                        detail: String(localized: "uncoil_run · uncoil_system · uncoil_browser · uncoil_computer")
                    )
                } control: {
                    Button(String(localized: "Capabilities…")) {
                        SettingsRoute.shared.requestedPane = SettingsView.Pane.permissions.rawValue
                    }
                    .settingsID("mcp.openPermissions")
                }
                SettingsNote(String(
                    localized: "Which of them a session may use is a permission, not a setting here: Computer Use, task deletion, orchestration, worktrees and merges stay off until granted."
                ))
            }
        }
    }
}
