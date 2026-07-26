import AppKit
import SwiftUI

/// Settings → Hakkında: version, where the data lives, and the two escape
/// hatches (a debug bundle to send, a clean uninstall).
struct AboutSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @State private var debugBundleURL: URL?
    @State private var debugBundleError: String?

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPage(title: String(localized: "About")) {
            Section {
                LabeledContent("Uncoil", value: version)
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "—")
            } footer: {
                SettingsNote(String(localized: "Developed by Gökhan Topbaş"))
            }

            Section {
                AdaptiveRow {
                    SettingsLabel(
                        title: String(localized: "Setup guide"),
                        detail: String(localized: "Runs the first-run flow again: CLIs, accounts, hooks, agent capabilities, tasks and extensions.")
                    )
                } control: {
                    Button("Run again") {
                        settings.resetOnboarding()
                        openWindow(id: "onboarding")
                    }
                    .settingsID("about.rerunOnboarding")
                }

                AdaptiveRow {
                    SettingsLabel(
                        title: String(localized: "Debug bundle"),
                        detail: String(localized: "Collects the logs and the configuration into one file; sensitive content is stripped.")
                    )
                } control: {
                    Button("Create") { createDebugBundle() }
                        .settingsID("about.debugBundle")
                }
            } header: {
                Text("Support")
            } footer: {
                if let debugBundleURL {
                    HStack {
                        Text(debugBundleURL.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textDim)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([debugBundleURL])
                        }
                    }
                } else if let debugBundleError {
                    SettingsNote(debugBundleError)
                }
            }
        }
    }

    private func createDebugBundle() {
        do {
            debugBundleURL = try DebugBundleService().create().bundleURL
            debugBundleError = nil
        } catch {
            debugBundleURL = nil
            debugBundleError = error.localizedDescription
        }
    }
}
