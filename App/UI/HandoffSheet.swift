import SwiftUI

/// Choosing where a session's work goes when its account is running out.
///
/// A sheet rather than a menu because the choice is not one line long: it is
/// worth seeing what is about to be handed over, and what each destination has
/// left, before deciding. The last option is always to do nothing — a warning
/// that only offered ways to act would be a warning that had already decided.
struct HandoffSheet: View {
    let session: SessionRecord
    let accountName: String?
    let evaluation: UsageAlert.Evaluation

    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var usage: UsageStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var service: HandoffService
    @State private var askAgent = true
    @State private var chosen: HandoffDestination?
    /// The running handoff, held so closing the sheet can actually stop it.
    /// Without this, asking the outgoing agent pinned the user in front of a
    /// spinner for up to three minutes with no way out.
    @State private var runTask: Task<Void, Never>?

    /// Set by the caller so a completed handoff can move the user to the new
    /// session rather than leaving them looking at a sheet.
    var onOpenSession: ((UUID) -> Void)?

    init(
        session: SessionRecord,
        accountName: String?,
        evaluation: UsageAlert.Evaluation,
        projectStore: ProjectStore,
        sessionStore: SessionStore,
        settings: SettingsStore,
        onOpenSession: ((UUID) -> Void)? = nil
    ) {
        self.session = session
        self.accountName = accountName
        self.evaluation = evaluation
        self.onOpenSession = onOpenSession
        _service = StateObject(wrappedValue: HandoffService(
            projectStore: projectStore, sessionStore: sessionStore, settings: settings
        ))
    }

    private var destinations: [HandoffDestination] {
        HandoffService.destinations(
            from: UsageKey(provider: session.provider, accountID: session.accountID),
            accounts: settings.accounts,
            // The same empty-cache trap as the producer: `binaryPath` is only
            // filled once the app has resolved the CLIs through the login
            // shell, so on a fresh profile every provider reads as missing and
            // the list comes up empty. Falling back to PATH is what makes the
            // destinations real rather than a function of start-up timing.
            installedProviders: Set(AgentProvider.agents.filter { provider in
                settings.binaryPath(for: provider) != nil
                    || provider.launchCommand.flatMap { AgentAdapterSupport.locateBinary($0) } != nil
            }),
            usage: usage.entries,
            threshold: settings.usageWarningThreshold
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)

            switch service.phase {
            case .idle:
                chooser
            case .askingOutgoingAgent, .startingNewSession:
                progress
            case .done(let newSessionID):
                finished(newSessionID)
            case .failed(let message):
                failure(message)
            }
        }
        .frame(width: 460)
        .background(Theme.panel)
        // `.contain` matters: an identifier on a container makes SwiftUI treat
        // the whole thing as one accessibility element and hide its children,
        // so every button inside became invisible — to VoiceOver as much as to
        // a test.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("handoff.sheet")
        // What the sheet actually computed, so a UI test can read it. The list
        // being empty and the list never being drawn look identical from
        // outside, and telling them apart by reading code failed repeatedly.
        .accessibilityValue(
            "\(destinations.count) destinations from \(session.provider.rawValue)"
                + " account=\(session.accountID?.uuidString ?? "default")"
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: session.provider, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(Theme.mono(.large, .bold))
                    .foregroundStyle(Theme.text)
                Text(session.displayTitle)
                    .font(Theme.mono(.small))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var headline: String {
        let account = accountName.map { "\(session.provider.displayName) · \($0)" }
            ?? session.provider.displayName
        guard let remaining = evaluation.remainingPercent else {
            return String(localized: "\(account) has stopped accepting work")
        }
        return String(localized: "\(account) · \(remaining)% remaining")
    }

    // MARK: - Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            if destinations.isEmpty {
                Text(String(
                    localized: "There is no other agent installed to hand this work to."
                ))
                .font(Theme.mono(.body))
                .foregroundStyle(Theme.textDim)
                .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(destinations) { destination in
                        destinationRow(destination)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)

                Divider().overlay(Theme.border)

                Toggle(isOn: $askAgent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Ask this agent what it was doing first"))
                            .font(Theme.mono(.body))
                            .foregroundStyle(Theme.text)
                        // The honest description of what the toggle buys and
                        // what it costs. The branch, the diff and the changed
                        // files go either way.
                        Text(String(
                            localized: "Takes up to a minute and uses a little of the remaining quota. Without it the handover still carries the branch, the changed files and the diff — but not what was decided."
                        ))
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .accessibilityIdentifier("handoff.askAgent")
            }

            Divider().overlay(Theme.border)

            HStack {
                Spacer()
                Button(String(localized: "Keep using this account")) { dismiss() }
                    .accessibilityIdentifier("handoff.keep")
            }
            .padding(14)
        }
    }

    private func destinationRow(_ destination: HandoffDestination) -> some View {
        Button {
            chosen = destination
            runTask = Task {
                await service.run(
                    session: session,
                    accountName: accountName,
                    destination: destination,
                    remainingPercent: evaluation.remainingPercent,
                    windowTitle: evaluation.window?.title,
                    askAgent: askAgent
                )
            }
        } label: {
            HStack(spacing: 10) {
                ProviderMark(provider: destination.provider, size: 15)
                Text(String(localized: "Continue with \(destination.label)"))
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let remaining = destination.remainingPercent {
                    Text("\(remaining)%")
                        .font(Theme.mono(.small, .medium))
                        .foregroundStyle(destination.isAlerting ? Theme.warn : Theme.ok)
                        .monospacedDigit()
                } else {
                    // Offered, but not dressed up as a promise of room.
                    Text(String(localized: "usage unknown"))
                        .font(Theme.mono(.small))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panelHover, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("handoff.destination.\(destination.id)")
    }

    // MARK: - Working

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(service.phase == .askingOutgoingAgent
                     ? String(localized: "Asking \(session.provider.displayName) what it was doing…")
                     : String(localized: "Starting \(chosen?.label ?? "")…"))
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.textDim)
            }
            if service.phase == .askingOutgoingAgent {
                Text(String(
                    localized: "It writes a handover file and stops. If it cannot answer, the handoff goes ahead with what Uncoil already knows."
                ))
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    // Only while asking: nothing has moved yet, so stopping is
                    // still a clean "never mind". Once the new session is being
                    // started there is no honest way back, and a cancel button
                    // that could not deliver would be worse than none.
                    Button(String(localized: "Cancel")) {
                        runTask?.cancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("handoff.cancel")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - Done

    private func finished(_ newSessionID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TablerIcon(name: "circle-check", size: 15, color: Theme.ok)
                Text(String(localized: "\(chosen?.label ?? "") has the work"))
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.text)
            }
            // Said plainly, because the difference matters to whoever reads the
            // next session: a handover without the agent's notes is a handover
            // from the repository, not from the agent.
            // The reason, not a shrug. Every failure path already records why
            // the outgoing agent produced nothing, and printing one fixed
            // sentence over the top of it cost four rounds of guessing at a
            // cause the app already knew.
            Text(service.package?.agentResponded == true
                 ? String(localized: "It was given the previous agent's notes, the branch, the changed files and the diff.")
                 : String(localized: "The previous agent did not answer (\(service.package?.agentFailureReason ?? "no reason recorded")), so the handover carries only what Uncoil knows: the branch, the changed files and the diff."))
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("handoff.outcome")
            Text(String(localized: "The old session is still running and was not closed."))
                .font(Theme.mono(.small))
                .foregroundStyle(Theme.textFaint)

            HStack {
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                Button(String(localized: "Open it")) {
                    onOpenSession?(newSessionID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("handoff.open")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TablerIcon(name: "alert-circle", size: 15, color: Theme.danger)
                Text(message)
                    .font(Theme.mono(.body))
                    .foregroundStyle(Theme.text)
            }
            HStack {
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}
