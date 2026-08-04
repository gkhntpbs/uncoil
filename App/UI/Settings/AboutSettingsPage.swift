import AppKit
import SwiftUI

/// Settings → Hakkında: version, where the data lives, and the two escape
/// hatches (a debug bundle to send, a clean uninstall).
struct AboutSettingsPage: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updater = UpdaterService.shared
    @State private var debugBundleURL: URL?
    @State private var debugBundleError: String?

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    /// "Never checked" is the honest answer on a fresh install, and a more
    /// useful one than an empty row.
    private var lastCheckDescription: String {
        guard let date = updater.lastCheckDate else {
            return String(localized: "Has not checked for updates yet.")
        }
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Last checked \(formatted).")
    }

    var body: some View {
        SettingsPage(title: String(localized: "About")) {
            Section {
                LabeledContent("Uncoil", value: version)
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "—")
            } footer: {
                SettingsNote(String(localized: "Developed by Gökhan Topbaş"))
            }

            if updater.isAvailable {
                Section {
                    AdaptiveRow {
                        SettingsLabel(
                            title: String(localized: "Check automatically"),
                            detail: String(localized: "Asks once a day whether a newer version has been published, and tells you only when there is one.")
                        )
                    } control: {
                        Toggle("", isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.automaticallyChecksForUpdates = $0 }
                        ))
                        .labelsHidden()
                        .settingsID("about.automaticUpdates")
                    }

                    AdaptiveRow {
                        SettingsLabel(
                            title: String(localized: "Updates"),
                            detail: lastCheckDescription
                        )
                    } control: {
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                            .settingsID("about.checkForUpdates")
                    }
                } header: {
                    Text("Software Update")
                } footer: {
                    SettingsNote(String(localized: "Updates are downloaded from uncoil.gokhantopbas.com and verified against a signature before they are installed."))
                }
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
                        OnboardingPresenter.shared.present()
                        // The flow lives in the main window; Settings is its
                        // own, so bring that one forward with it.
                        openWindow(id: "main")
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
