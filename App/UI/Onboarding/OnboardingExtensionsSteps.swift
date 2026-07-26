import SwiftUI

// MARK: - Extensions

/// The extension store, introduced through its safety model first.
///
/// What the user is being asked here is whether Uncoil should manage the skills
/// and MCP servers they already installed by hand. That is a real move of files,
/// so nothing happens without the button — and every adoption goes through the
/// same planner the Extensions window uses, backup and all.
struct OnboardingExtensionsStep: View {
    @StateObject private var registry = ExtensionRegistry()
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    @State private var scanning = true
    @State private var message: String?
    @State private var adopting = false

    /// External installs Uncoil could take over: found on disk, not blocked by a
    /// security finding.
    private var adoptable: [ExtensionPackage] {
        registry.unmanagedPackages.filter { package in
            if case .detectedExternal = package.source { return blockers(for: package).isEmpty }
            return false
        }
    }

    private func blockers(for package: ExtensionPackage) -> [SecurityFinding] {
        registry.findings.filter {
            $0.extensionID == package.id && $0.severity == .blocked && !$0.isAccepted
        }
    }

    var body: some View {
        OnboardingScaffold(
            step: .extensions,
            title: String(localized: "Skills and MCP servers, with a safety net"),
            subtitle: String(localized: "Uncoil keeps one store for the extensions your agents use, and scans everything before it goes in."),
            primaryTitle: String(localized: "Continue"),
            primaryAction: onContinue,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                OnboardingCard(
                    symbol: "shield.lefthalf.filled",
                    title: String(localized: "How the scanner rates a package"),
                    detail: String(localized: "Every package is read before it is installed or adopted: risky shell constructs, executables, its source and its licence. A clean scan is never called “safe” — Verified is reserved for what Uncoil itself ships.")
                ) {
                    HStack(spacing: 6) {
                        ForEach(ExtensionSecurityScanner.RiskLevel.allCases, id: \.rawValue) { level in
                            OnboardingBadge(text: level.label, tint: tint(for: level))
                        }
                    }
                    .padding(.top, 2)
                    Text("A Blocked finding stops adoption outright; nothing about it can be clicked past here.")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                OnboardingCard(
                    symbol: "square.and.arrow.down.on.square",
                    title: String(localized: "Take over what you already installed"),
                    badge: scanning ? String(localized: "Scanning…") : nil,
                    detail: String(localized: "Skills and MCP servers found in your agents' own directories. Adopting copies them into Uncoil's store after writing a backup; anything you leave here stays exactly where it is.")
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !scanning && adoptable.isEmpty {
                            Text("Nothing to adopt — no external skill or MCP server was found.")
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.textFaint)
                        }
                        ForEach(adoptable.prefix(6)) { package in
                            HStack(spacing: 8) {
                                Text(package.name)
                                    .font(Theme.mono(.body))
                                    .foregroundStyle(Theme.text)
                                OnboardingBadge(text: package.kind.label)
                                Spacer(minLength: 0)
                            }
                        }
                        if adoptable.count > 6 {
                            Text("+\(adoptable.count - 6) more")
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.textFaint)
                        }
                        if !adoptable.isEmpty {
                            Button(adopting
                                   ? String(localized: "Adopting…")
                                   : String(localized: "Let Uncoil manage these (\(adoptable.count))")) {
                                adoptAll()
                            }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(adopting)
                            .accessibilityIdentifier("onboarding.adoptAll")
                        }
                        if let message {
                            Text(message)
                                .font(Theme.mono(.small))
                                .foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("Installing the optional browser or Computer Use drivers, and running any remote install script, always asks you first.")
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                OnboardingSkipLink(action: onSkip)
            }
        }
        .task {
            registry.discover()
            scanning = false
        }
    }

    private func tint(for level: ExtensionSecurityScanner.RiskLevel) -> Color {
        switch level {
        case .verified: Theme.ok
        case .lowRisk: Theme.textDim
        case .modifiedLocally, .needsReview: Theme.warn
        case .highRisk, .blocked: Theme.danger
        }
    }

    /// The same sequence the Extensions window runs: one plan per package, each
    /// with its own backup, and an honest report of what did not go through.
    private func adoptAll() {
        adopting = true
        let service = ExtensionAdoptionService(layout: registry.layout)
        var adopted: [String] = []
        var failures: [String] = []
        for package in adoptable {
            guard case .detectedExternal(let path) = package.source else { continue }
            do {
                let findings = registry.findings.filter { $0.extensionID == package.id }
                let plan: ExtensionAdoptionService.Plan
                if package.kind == .mcpServer {
                    guard let definition = registry.definition(named: package.name) else {
                        failures.append(package.name)
                        continue
                    }
                    plan = try service.planDefinition(
                        definition,
                        agents: registry.agents(declaring: package.name),
                        findings: findings
                    )
                } else {
                    plan = try service.plan(
                        name: package.name, kind: package.kind, externalPath: path,
                        findings: findings, installations: registry.installations
                    )
                }
                let result = try service.adopt(plan)
                registry.remove(packageID: package.id)
                registry.upsert(result)
                for copy in plan.agentCopies {
                    registry.setAgentBinding(true, packageID: result.id, agent: copy.agent)
                }
                adopted.append(package.name)
            } catch {
                failures.append("\(package.name) (\(error.localizedDescription))")
            }
        }
        registry.discover()
        var parts: [String] = []
        if !adopted.isEmpty {
            parts.append(String(localized: "Adopted: \(adopted.joined(separator: ", "))"))
        }
        if !failures.isEmpty {
            parts.append(String(localized: "Left alone: \(failures.joined(separator: ", "))"))
        }
        message = parts.joined(separator: " · ")
        adopting = false
    }
}

// MARK: - Finish

/// The last page: the four things worth knowing on day one, and a way in.
struct OnboardingFinishStep: View {
    @EnvironmentObject private var settings: SettingsStore
    let onFinish: () -> Void
    let onBack: () -> Void
    let onSkipAll: () -> Void

    var body: some View {
        OnboardingScaffold(
            step: .finish,
            title: String(localized: "You're set up"),
            subtitle: String(localized: "Four things that make the difference on day one."),
            primaryTitle: String(localized: "Start working"),
            primaryAction: onFinish,
            onBack: onBack,
            onSkipAll: onSkipAll
        ) {
            VStack(spacing: 12) {
                OnboardingCard(
                    symbol: "rectangle.3.group",
                    title: String(localized: "Project → worktree → session"),
                    detail: String(localized: "Hover a project and pick an agent. Several agents can work the same repository at once, each in its own git worktree, without touching each other's files.")
                )
                OnboardingCard(
                    symbol: "circle.dotted",
                    title: String(localized: "Status and the attention list"),
                    detail: String(localized: "Every session shows working, needs input or done. Anything waiting on you collects in the Attention Center and in the menu-bar monitor.")
                )
                OnboardingCard(
                    symbol: "command",
                    title: String(localized: "The command palette"),
                    detail: String(localized: "\(settings.commandPaletteHotkey.displayString) opens it: projects, sessions, tasks and settings from the keyboard.")
                )
                OnboardingCard(
                    symbol: "checklist",
                    title: String(localized: "Tasks and the control plane"),
                    detail: String(localized: "The Tasks tab hands work out from TODO.md, and your agents can reach back into Uncoil through its MCP tools. Both are tunable in Settings.")
                )

                if !settings.remainingOnboardingSteps.isEmpty {
                    Text("Anything you skipped stays listed at the bottom of the sidebar under “Finish setup”.")
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
