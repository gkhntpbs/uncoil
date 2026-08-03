import AppKit
import SwiftUI

// MARK: - Working modes

/// How much rope each agent gets, asked once instead of discovered per session.
///
/// The mode is what every new session of that provider starts in, and it is the
/// difference between an agent that stops at each edit and one that does not
/// stop at all. Leaving it to whatever the CLI defaults to meant people found
/// out which they had by watching an agent act.
struct OnboardingWorkingModesStep: View {
    @EnvironmentObject private var settings: SettingsStore
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    private let providers: [AgentProvider] = AgentProvider.agents

    var body: some View {
        OnboardingScaffold(
            step: .workingModes,
            title: String(localized: "How much should an agent do on its own?"),
            subtitle: String(localized: "This is the mode every new session starts in. You can change it per session at any time, and change the default later in Settings."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll,
            footnote: String(localized: "Uncoil never raises a session above the mode you pick here — a child agent inherits its parent's, intersected, and cannot escalate.")
        ) {
            VStack(spacing: 12) {
                ForEach(providers) { provider in
                    OnboardingCard(
                        symbol: "slider.horizontal.3",
                        title: provider.displayName,
                        detail: modeDetail(for: provider)
                    ) {
                        Picker("", selection: Binding(
                            get: { settings.workingMode(for: provider) },
                            set: { settings.setWorkingMode($0, for: provider) }
                        )) {
                            ForEach(AgentWorkingMode.options(for: provider)) { mode in
                                Text(mode.label(for: provider)).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 280)
                        .accessibilityIdentifier("onboarding.workingMode.\(provider.rawValue)")
                    }
                }

                OnboardingSkipLink(action: onSkip)
            }
        }
    }

    /// Says what the chosen mode actually means, rather than describing the
    /// picker. The riskiest option is named as such where it is chosen.
    private func modeDetail(for provider: AgentProvider) -> String {
        switch settings.workingMode(for: provider) {
        case .manual, .askForApproval:
            String(localized: "Asks before it edits a file or runs a command.")
        case .acceptEdits:
            String(localized: "Edits files without asking; still asks before running commands.")
        case .plan:
            String(localized: "Reads and plans, and changes nothing until you accept the plan.")
        case .auto, .approveForMe:
            String(localized: "Works through the task on its own, inside the project's folder.")
        case .fullAccess, .dangerouslySkipPermissions:
            String(localized: "Never asks — including for commands outside the project. Pick this only for a session you are watching.")
        default:
            String(localized: "Whatever the CLI does by default.")
        }
    }
}

// MARK: - Optional tools

/// The three binaries Uncoil can set up but does not ship.
///
/// Every one of them is a download, so every one of them is a button. Nothing
/// on this page runs without being pressed, no install script is executed, and
/// skipping it costs only the feature it belongs to — which is what each card
/// says, so "not now" is an informed answer rather than a shrug.
struct OnboardingToolsStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var bumblebee: [BumblebeeBinary] = []
    @State private var bumblebeePhase: BumblebeeInstaller.Phase?
    @State private var bumblebeeMessage: String?
    @State private var installingBumblebee = false

    @State private var cua: DependencyInfo?
    @State private var browser: DependencyInfo?

    private let locator = BumblebeeLocator.default()

    var body: some View {
        OnboardingScaffold(
            step: .tools,
            title: String(localized: "Optional tools"),
            subtitle: String(localized: "Three things Uncoil can use but does not ship. Each is a download, so each is a button — nothing here installs itself, and no install script is ever run."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                bumblebeeCard
                cuaCard
                browserCard
                OnboardingSkipLink(action: onSkip)
            }
        }
        .task {
            bumblebee = locator.available()
            await refreshDrivers()
        }
    }

    // MARK: Bumblebee

    private var bumblebeeInstalled: Bool { !bumblebee.isEmpty }

    private var bumblebeeCard: some View {
        OnboardingCard(
            symbol: "shield.lefthalf.filled",
            title: String(localized: "Bumblebee scanner"),
            badge: bumblebeeInstalled
                ? String(localized: "Installed")
                : String(localized: "Not installed"),
            badgeTint: bumblebeeInstalled ? Theme.ok : Theme.textDim,
            detail: String(localized: "A second opinion on every extension. Uncoil scans packages itself either way; Bumblebee adds a deeper pass. Uncoil fetches the release from the project's own GitHub and checks it against the checksums published with it — the archive is unpacked, never executed.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !bumblebeeInstalled {
                    Button(installingBumblebee
                           ? String(localized: "Installing…")
                           : String(localized: "Download and install Bumblebee")) {
                        installBumblebee()
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(installingBumblebee)
                    .accessibilityIdentifier("onboarding.bumblebee.install")
                }
                if let bumblebeePhase {
                    ProgressView(value: bumblebeePhase.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .tint(Theme.highlight)
                    Text(bumblebeePhase.label)
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textFaint)
                }
                if let bumblebeeMessage {
                    Text(bumblebeeMessage)
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Skipping this changes nothing about how extensions are scanned today.")
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func installBumblebee() {
        installingBumblebee = true
        bumblebeeMessage = nil
        bumblebeePhase = .askingGitHub
        let installer = BumblebeeInstaller(destinationDirectory: locator.managedDirectory)
        Task {
            do {
                let installed = try await installer.install { step in
                    Task { @MainActor in bumblebeePhase = step }
                }
                bumblebeeMessage = String(localized: "\(installed.releaseTag) installed.")
                bumblebee = locator.available()
            } catch {
                bumblebeeMessage = String(
                    localized: "Could not install: \(error.localizedDescription)"
                )
            }
            bumblebeePhase = nil
            installingBumblebee = false
        }
    }

    // MARK: Drivers

    private var cuaCard: some View {
        OnboardingCard(
            symbol: "display",
            title: String(localized: "Cua Driver — Computer Use"),
            badge: cua?.installed == true
                ? String(localized: "Installed")
                : String(localized: "Not installed"),
            badgeTint: cua?.installed == true ? Theme.ok : Theme.textDim,
            detail: String(localized: "What lets an agent drive the Mac itself: real windows, real clicks, your screen. It needs Accessibility and Screen Recording permission, which only you can grant, so its installer walks you through it rather than Uncoil doing it behind your back.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if cua?.installed != true {
                    Button(String(localized: "Open the setup guide")) {
                        open("https://cua.ai/docs/how-to-guides/driver/install")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("onboarding.cua.installGuide")
                }
                Text("Computer Use stays off for every session until you turn it on, whether the driver is installed or not.")
                    .font(Theme.ui(.small))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var browserCard: some View {
        OnboardingCard(
            symbol: "globe",
            title: String(localized: "Agent browser"),
            badge: browser?.installed == true
                ? String(localized: "Installed")
                : String(localized: "Not installed"),
            badgeTint: browser?.installed == true ? Theme.ok : Theme.textDim,
            detail: String(localized: "A Chromium the agent drives on its own, in a blank profile with none of your logins in it. Without the driver the browser tools simply report that they are unavailable.")
        ) {
            Text("Installed from Settings › Permissions, where the driver's own setup runs. It is a separate download, so it asks first.")
                .font(Theme.ui(.small))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshDrivers() async {
        let probed = await Task.detached(priority: .utility) {
            (CuaDriverAdapter().probe(), AgentBrowserAdapter().probe())
        }.value
        cua = probed.0
        browser = probed.1
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
