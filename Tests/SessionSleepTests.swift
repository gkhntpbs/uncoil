import XCTest
@testable import Uncoil

/// Suspending and hibernating are not degrees of the same thing, and the
/// difference is load-bearing: one signals a process that is still there, the
/// other ends it and rebuilds the session from the provider's own resume.
final class SessionSleepTests: XCTestCase {
    // MARK: - Suspend

    func testARunningSessionCanBePaused() {
        for status in [.idle, .thinking, .running, .waitingForInput] as [AgentSessionStatus] {
            XCTAssertNoThrow(
                try SessionSleep.canSuspend(status: status).get(), status.rawValue
            )
        }
    }

    func testAClosedSessionHasNothingToPause() {
        XCTAssertEqual(
            SessionSleep.canSuspend(status: .terminated).failure, .notRunning
        )
    }

    func testPausingTwiceSaysSoRatherThanSilentlyDoingNothing() {
        XCTAssertEqual(
            SessionSleep.canSuspend(status: .suspended).failure, .already(.suspended)
        )
    }

    /// Suspending only signals a process, so it asks nothing of the provider.
    func testEvenAPlainShellCanBePaused() {
        XCTAssertNoThrow(try SessionSleep.canSuspend(status: .running).get())
        XCTAssertFalse(AgentProvider.terminal.resumesConversation)
    }

    // MARK: - Hibernate

    func testAnAgentThatResumesCanHibernate() {
        for provider in [.claude, .codex] as [AgentProvider] {
            XCTAssertNoThrow(
                try SessionSleep.canHibernate(
                    status: .idle, provider: provider, providerSessionID: "prov-1"
                ).get(),
                provider.rawValue
            )
        }
    }

    /// The whole reason hibernation is gated. Waking a provider that cannot
    /// resume would start a new conversation, and there is no honest way to
    /// label that as picking up where it left off.
    func testAProviderThatCannotResumeIsNeverOfferedHibernation() {
        for provider in [.gemini, .terminal] as [AgentProvider] {
            XCTAssertEqual(
                SessionSleep.canHibernate(
                    status: .idle, provider: provider, providerSessionID: "prov-1"
                ).failure,
                .cannotResume,
                provider.rawValue
            )
        }
    }

    /// Provider support is not enough: without an id there is nothing to resume
    /// with. An agent that has not reported one yet is in exactly this state.
    func testHibernationNeedsAnIdToResumeFromNotJustAWillingProvider() {
        XCTAssertEqual(
            SessionSleep.canHibernate(
                status: .idle, provider: .claude, providerSessionID: nil
            ).failure,
            .cannotResume
        )
        XCTAssertEqual(
            SessionSleep.canHibernate(
                status: .idle, provider: .claude, providerSessionID: ""
            ).failure,
            .cannotResume
        )
    }

    /// The natural escalation: parked for now, then parked properly. Its
    /// process is still there to be ended.
    func testAPausedSessionCanStillBeHibernated() {
        XCTAssertNoThrow(
            try SessionSleep.canHibernate(
                status: .suspended, provider: .claude, providerSessionID: "prov-1"
            ).get()
        )
    }

    func testAClosedSessionCannotHibernate() {
        XCTAssertEqual(
            SessionSleep.canHibernate(
                status: .terminated, provider: .claude, providerSessionID: "prov-1"
            ).failure,
            .notRunning
        )
    }

    // MARK: - Waking

    func testOnlyASleepingSessionCanBeWoken() {
        XCTAssertTrue(SessionSleep.canWake(status: .suspended))
        XCTAssertTrue(SessionSleep.canWake(status: .hibernated))
        for status in [.idle, .running, .terminated] as [AgentSessionStatus] {
            XCTAssertFalse(SessionSleep.canWake(status: status), status.rawValue)
        }
    }

    /// A suspended process never stopped owning its screen, so touching it
    /// would destroy exactly the state pausing preserved. A hibernated one
    /// redraws its own conversation through `--resume`, so keeping the old
    /// scrollback would show it twice.
    func testOnlyHibernationClearsTheTerminalOnWake() {
        XCTAssertFalse(SessionSleep.clearsTerminalOnWake(from: .suspended))
        XCTAssertTrue(SessionSleep.clearsTerminalOnWake(from: .hibernated))
    }

    func testOnlyHibernationRelaunches() {
        XCTAssertFalse(SessionSleep.relaunchesOnWake(from: .suspended))
        XCTAssertTrue(SessionSleep.relaunchesOnWake(from: .hibernated))
    }

    // MARK: - Status

    func testASleepingSessionIsNotConsideredRunning() {
        XCTAssertFalse(SessionSleep.isRunning(.suspended))
        XCTAssertFalse(SessionSleep.isRunning(.hibernated))
    }

    /// Asleep on purpose: there is nothing to answer, so nothing to nag about.
    func testASleepingSessionNeverAsksForAttention() {
        XCTAssertFalse(AgentSessionStatus.suspended.needsAttention)
        XCTAssertFalse(AgentSessionStatus.hibernated.needsAttention)
    }

    /// A session frozen mid-action still has work in flight and cannot react to
    /// files moving under it. A hibernated one has no process at all, and
    /// calling it "working" would block worktree operations forever.
    func testPausedCountsAsWorkingButAsleepDoesNot() {
        XCTAssertTrue(AgentSessionStatus.suspended.isWorking)
        XCTAssertFalse(AgentSessionStatus.hibernated.isWorking)
    }

    /// The resume flag on the launch command and the hibernation gate must be
    /// the same fact, or a session could be hibernated and then woken without a
    /// resume.
    func testTheHibernationGateMatchesTheLaunchCommand() throws {
        for provider in AgentProvider.allCases {
            var record = SessionRecord(
                projectID: UUID(), provider: provider, accountID: nil, title: "s"
            )
            record.providerSessionID = "prov-1"
            guard let command = TerminalRegistry.launchCommand(
                for: record, extraArguments: nil
            ) else {
                XCTAssertFalse(provider.resumesConversation, provider.rawValue)
                continue
            }
            XCTAssertEqual(
                command.contains("resume"), provider.resumesConversation,
                "\(provider.rawValue): \(command)"
            )
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
