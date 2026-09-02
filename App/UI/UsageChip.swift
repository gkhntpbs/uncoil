import SwiftUI

// MARK: - Severity colour

extension UsageDisplay.Severity {
    /// Three bands, three colours, and a fourth that is deliberately not a
    /// colour: an unknown limit is drawn in the same faint grey as any other
    /// missing metadata, because tinting it green or red would be answering a
    /// question nobody could answer.
    @MainActor
    var color: Color {
        switch self {
        case .healthy: Theme.ok
        case .low: Theme.warn
        case .critical: Theme.danger
        case .unknown: Theme.textFaint
        }
    }
}

// MARK: - The ring

/// A circular gauge of what is left.
///
/// A ring rather than a bar for the chip because it survives being small: at
/// this size a bar is a few pixels of fill and reads as a smudge, while an arc
/// still shows its own emptiness. The track is always drawn, so the shape is
/// stable whatever the number — a partial ring alone would change size as it
/// drains and drag the text beside it around.
struct UsageRing: View {
    /// 0...100, or nil when there is no reading.
    var remainingPercent: Double?
    var severity: UsageDisplay.Severity
    /// Small enough to sit in the metadata line without competing with it: the
    /// account and the path are what that row is for, and the figure is an
    /// aside until it is low.
    var size: CGFloat = 11.5
    var lineWidth: CGFloat = 2
    /// Draws the arc hollow, for a figure that is being kept rather than
    /// refreshed.
    var stale: Bool = false

    var body: some View {
        ZStack {
            if let remainingPercent {
                Circle()
                    .stroke(Theme.border, lineWidth: lineWidth)
                Circle()
                    // Exactly nothing left draws exactly nothing. A floor kept
                    // a sliver visible for very small values, which is right —
                    // "a little" should be seeable — but at zero it drew a dot,
                    // and a dot in the one state that means *stop* reads as
                    // "there is still a bit".
                    .trim(from: 0, to: remainingPercent <= 0
                        ? 0
                        : max(0.02, min(1, remainingPercent / 100)))
                    .stroke(
                        severity.color.opacity(stale ? 0.45 : 1),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    // Starts at the top and fills clockwise, the way a dial is
                    // read. SwiftUI's trim starts at three o'clock.
                    .rotationEffect(.degrees(-90))
            } else {
                // No reading: a broken outline, which is the one shape that
                // cannot be mistaken for a number. A solid empty track reads as
                // zero — the most dangerous misreading there is here — and a
                // dash inside the ring only repeats what the "—" beside it
                // already says, while looking like a disabled control.
                Circle()
                    .stroke(
                        Theme.textFaint.opacity(0.7),
                        style: StrokeStyle(
                            lineWidth: lineWidth * 0.8,
                            dash: [size * 0.16, size * 0.16]
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .animation(Theme.Motion.standard, value: remainingPercent)
    }
}

/// One-shot gate for `-usage-fixture`, held outside any view so that
/// presenting the card cannot re-arm it.
@MainActor
enum UsageCardAutoOpen {
    private static var used = false

    static func claim() -> Bool {
        guard !used else { return false }
        used = true
        return true
    }
}

// MARK: - The chip

/// The usage figure in a session's header, beside the account it belongs to.
///
/// Beside it deliberately: a limit is a property of the account, not of the
/// session, and two sessions on two logins have two different answers. Putting
/// the number anywhere else would invite it to be read as this session's.
///
/// The chip shows one number — whichever window binds first — because that is
/// the only figure a glance can use. Everything else is a click away.
struct UsageChip: View {
    let provider: AgentProvider
    let account: AccountProfile?
    let isWorking: Bool
    /// The session the chip sits beside. Present means a handoff can be
    /// offered; the figure itself belongs to the account either way.
    var session: SessionRecord?
    /// Asked for rather than presented here. A sheet put up from inside a
    /// popover that is closing in the same breath never appears: the popover's
    /// dismissal tears down the view the presentation was attached to. The
    /// header owns it instead, because the header is still there afterwards.
    var onRequestHandoff: ((UsageAlert.Evaluation) -> Void)?

    @EnvironmentObject private var usage: UsageStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var showCard = false
    @State private var hovering = false
    /// Ticks while the card is open so "in 2h 14m" keeps counting rather than
    /// freezing at whatever it said when the popover appeared.
    @State private var now = Date()

    private var key: UsageKey { UsageKey(provider: provider, accountID: account?.id) }
    private var entry: UsageEntry { usage.entry(for: key) }
    private var snapshot: UsageSnapshot? { entry.snapshot }

    private var context: UsageAccountContext {
        UsageAccountContext(
            accountID: account?.id,
            label: account?.name,
            configDirectory: account?.configDirectory(profilesRoot: settings.profilesRootURL)
        )
    }

    /// A limit only moves while the agent is working, so an idle session is
    /// asked far less often. The store turns this into a cadence; the view only
    /// has to say which of the two it is looking at.
    private var activity: UsageActivity { isWorking ? .active : .idle }

    private var severity: UsageDisplay.Severity {
        UsageDisplay.severity(of: snapshot, threshold: settings.usageWarningThreshold)
    }
    private var remaining: Int? { UsageDisplay.headlineRemaining(snapshot) }

    var body: some View {
        Button {
            showCard.toggle()
        } label: {
            HStack(spacing: 4) {
                UsageRing(
                    remainingPercent: snapshot?.mostConstrainedWindow?.remainingPercent,
                    severity: severity,
                    stale: entry.isStale
                )
                if let remaining {
                    Text("\(remaining)%")
                        .font(Theme.mono(.small, .medium))
                        .foregroundStyle(entry.isStale ? Theme.textFaint : severity.color)
                        .monospacedDigit()
                } else {
                    // No number, and no placeholder pretending to be one.
                    Text(verbatim: "—")
                        .font(Theme.mono(.small, .medium))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                hovering ? Theme.panelHover : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.chip)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .help(UsageDisplay.chipHelp(snapshot, now: now))
        .accessibilityIdentifier("session.usageChip")
        .accessibilityValue(remaining.map { "\($0)% remaining" } ?? "unavailable")
        // A popover cannot be shown any other way than by being clicked, so a
        // deterministic run that wants to look at the card has to be handed it.
        //
        // The one-shot lives outside the view because presenting a popover
        // rebuilds the chip, and a `@State` guard is reset by that rebuild —
        // which reopens the card and rebuilds the chip again. The delay is for
        // the window: a popover asked for while it is still being assembled has
        // nothing to anchor to.
        .onAppear {
            guard LaunchConfig.shared.usageFixture, UsageCardAutoOpen.claim() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showCard = true }
        }
        .popover(isPresented: $showCard, arrowEdge: .bottom) {
            UsageCard(
                provider: provider,
                account: account,
                entry: entry,
                now: now,
                threshold: settings.usageWarningThreshold,
                onHandOff: (session == nil || onRequestHandoff == nil) ? nil : {
                    showCard = false
                    onRequestHandoff?(UsageAlert.evaluate(
                        snapshot, threshold: settings.usageWarningThreshold
                    ))
                },
                onRefresh: {
                    Task { await usage.refresh(key: key, account: context, userInitiated: true) }
                }
            )
        }
        // Driven from the chip because the chip is what is on screen: a session
        // nobody is looking at costs nothing, and the loop stops with the view.
        .task(id: key) {
            while !Task.isCancelled {
                now = Date()
                await usage.refreshIfDue(key: key, account: context, activity: activity)
                try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
            }
        }
    }
}
