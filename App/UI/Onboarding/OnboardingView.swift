import SwiftUI

/// The first-run flow.
///
/// Its job is to hand over the four things a new user cannot discover on their
/// own — which CLIs are installed, that status tracking needs a hook, what the
/// agents may do through the control plane, and that TODO.md and the extension
/// store exist — without ever standing in the way. Every step can be skipped,
/// and the whole flow can be left from the corner.
struct OnboardingView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore

    @State private var step: OnboardingStep = .welcome
    /// Project added during this run, so the Tasks step has something to scan.
    @State private var addedProjectPath: String?

    var body: some View {
        Group {
            switch step {
            case .welcome:
                OnboardingWelcomeStep(onContinue: advance, onSkipAll: skipAll)
            case .clis:
                OnboardingCLIStep(onContinue: complete, onSkip: advance, onBack: back, onSkipAll: skipAll)
            case .accounts:
                OnboardingAccountsStep(onContinue: complete, onSkip: advance, onBack: back, onSkipAll: skipAll)
            case .hooks:
                OnboardingHooksStep(onContinue: complete, onSkip: advance, onBack: back, onSkipAll: skipAll)
            case .notifications:
                OnboardingNotificationsStep(onContinue: complete, onSkip: advance, onBack: back, onSkipAll: skipAll)
            case .capabilities:
                OnboardingCapabilitiesStep(onContinue: complete, onSkip: advance, onBack: back, onSkipAll: skipAll)
            case .project:
                OnboardingProjectStep(
                    addedProjectPath: $addedProjectPath,
                    onContinue: complete, onSkip: advance, onBack: back, onSkipAll: skipAll
                )
            case .tasks:
                OnboardingTasksStep(
                    projectPath: addedProjectPath ?? projectStore.projects.first?.rootPath,
                    onContinue: complete, onSkip: advance, onBack: back, onSkipAll: skipAll
                )
            case .extensions:
                OnboardingExtensionsStep(onContinue: complete, onSkip: advance, onBack: back, onSkipAll: skipAll)
            case .palette:
                OnboardingPaletteStep(onContinue: complete, onSkip: advance, onBack: back, onSkipAll: skipAll)
            case .finish:
                OnboardingFinishStep(onFinish: skipAll, onBack: back, onSkipAll: skipAll)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .background(OnboardingWindowSizer().frame(width: 0, height: 0))
        .animation(Theme.Motion.standard, value: step)
        .onAppear {
            // Resuming lands on the first thing still undone; a first run has
            // nothing done, so that is the welcome.
            if let requested = LaunchConfig.shared.onboardingStep,
               let parsed = OnboardingStep(rawValue: requested) {
                step = parsed
            } else if !settings.onboardingCompletedSteps.isEmpty {
                step = OnboardingFlow.resumeStep(completed: settings.onboardingCompletedSteps)
            }
        }
    }

    /// Move on without claiming the step was done.
    private func advance() {
        guard let next = OnboardingFlow.next(after: step) else { return finish() }
        step = next
    }

    /// Move on and record the step as completed.
    private func complete() {
        settings.markOnboardingStepCompleted(step)
        advance()
    }

    private func back() {
        guard let previous = OnboardingFlow.previous(before: step) else { return }
        step = previous
    }

    /// Leaving the flow — from Skip or from the last page. Either way it is
    /// stamped as seen so it does not reopen by itself; what is left undone
    /// stays visible in the sidebar instead.
    private func skipAll() {
        finish()
    }

    private func finish() {
        settings.finishOnboarding()
        OnboardingPresenter.shared.dismiss()
    }
}

// MARK: - Resume row

/// The sidebar's reminder of what onboarding left undone. Shown only while
/// something actionable is still missing.
struct OnboardingResumeRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var hovering = false

    var body: some View {
        let remaining = settings.remainingOnboardingSteps
        if !remaining.isEmpty && !settings.shouldPresentOnboarding {
            Button {
                OnboardingPresenter.shared.present()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.highlight)
                    Text("Finish setup")
                        .font(Theme.ui(.small))
                        .foregroundStyle(Theme.textDim)
                    Spacer(minLength: 0)
                    Text("\(remaining.count)")
                        .font(Theme.ui(.micro, .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(hovering ? Theme.panelHover : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .accessibilityIdentifier("sidebar.finishSetup")
        }
    }
}
