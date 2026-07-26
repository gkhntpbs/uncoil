import XCTest
@testable import Uncoil

final class OnboardingFlowTests: XCTestCase {
    func testStepOrderIsWelcomeFirstAndFinishLast() {
        XCTAssertEqual(OnboardingFlow.all.first, .welcome)
        XCTAssertEqual(OnboardingFlow.all.last, .finish)
    }

    func testNextAndPreviousWalkTheFlow() {
        XCTAssertEqual(OnboardingFlow.next(after: .welcome), .clis)
        XCTAssertEqual(OnboardingFlow.previous(before: .clis), .welcome)
        XCTAssertNil(OnboardingFlow.next(after: .finish))
        XCTAssertNil(OnboardingFlow.previous(before: .welcome))
    }

    /// The bookends only explain, so they can never show up as work left over.
    func testRemainingCountsOnlyActionableSteps() {
        let remaining = OnboardingFlow.remaining(completed: [])
        XCTAssertFalse(remaining.contains(.welcome))
        XCTAssertFalse(remaining.contains(.finish))
        XCTAssertEqual(remaining.count, OnboardingStep.allCases.count - 2)
    }

    func testCompletedStepsDropOutOfRemaining() {
        let remaining = OnboardingFlow.remaining(
            completed: [OnboardingStep.clis.rawValue, OnboardingStep.project.rawValue]
        )
        XCTAssertFalse(remaining.contains(.clis))
        XCTAssertFalse(remaining.contains(.project))
        XCTAssertTrue(remaining.contains(.capabilities))
    }

    func testResumeLandsOnFirstUnfinishedStep() {
        XCTAssertEqual(
            OnboardingFlow.resumeStep(completed: [OnboardingStep.clis.rawValue]),
            .accounts
        )
        // Nothing left to do: there is nowhere to resume to.
        let everything = Set(OnboardingStep.allCases.filter(\.isActionable).map(\.rawValue))
        XCTAssertEqual(OnboardingFlow.resumeStep(completed: everything), .welcome)
    }

    func testPresentationIsGatedOnTheStampedVersion() {
        XCTAssertTrue(OnboardingFlow.shouldPresent(stampedVersion: nil))
        XCTAssertFalse(OnboardingFlow.shouldPresent(stampedVersion: OnboardingFlow.currentVersion))
        XCTAssertTrue(OnboardingFlow.shouldPresent(stampedVersion: OnboardingFlow.currentVersion - 1))
    }
}

@MainActor
final class OnboardingSettingsTests: XCTestCase {
    private func makeStore() throws -> SettingsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SettingsStore(directory: directory)
    }

    func testSkippingStampsTheVersionSoItDoesNotReopen() throws {
        let store = try makeStore()
        XCTAssertTrue(store.shouldPresentOnboarding)
        store.finishOnboarding()
        XCTAssertFalse(store.shouldPresentOnboarding)
        // …but what was skipped is still listed.
        XCTAssertFalse(store.remainingOnboardingSteps.isEmpty)
    }

    func testCompletedStepsSurviveAReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = SettingsStore(directory: directory)
        first.markOnboardingStepCompleted(.capabilities)
        first.finishOnboarding()

        let reloaded = SettingsStore(directory: directory)
        XCTAssertTrue(reloaded.onboardingCompletedSteps.contains(OnboardingStep.capabilities.rawValue))
        XCTAssertFalse(reloaded.shouldPresentOnboarding)
    }

    /// Re-selecting exactly the built-in set is stored as "no override", so a
    /// later change to the defaults still reaches newly created sessions.
    func testDefaultCapabilitySelectionIsNotPersistedAsAnOverride() throws {
        let store = try makeStore()
        store.setSessionCapabilityDefaults(PolicyEngine.defaultGrants)
        XCTAssertNil(store.sessionCapabilityDefaults)
        XCTAssertNil(ProjectStore.defaultSessionCapabilities)
        XCTAssertEqual(store.effectiveSessionCapabilities, PolicyEngine.defaultGrants)
    }

    func testOptingIntoComputerUseIsStampedOntoNewSessions() throws {
        let store = try makeStore()
        store.setSessionCapabilityDefaults(
            PolicyEngine.defaultGrants.union(["computer.inspect"])
        )
        XCTAssertEqual(
            ProjectStore.defaultSessionCapabilities.map(Set.init),
            PolicyEngine.defaultGrants.union(["computer.inspect"])
        )
        XCTAssertTrue(store.effectiveSessionCapabilities.contains("computer.inspect"))
        // Leave the process-wide mirror as it was found.
        store.setSessionCapabilityDefaults(nil)
    }

    func testResetSendsTheUserThroughTheFlowAgain() throws {
        let store = try makeStore()
        store.markOnboardingStepCompleted(.clis)
        store.finishOnboarding()
        store.resetOnboarding()
        XCTAssertTrue(store.shouldPresentOnboarding)
        XCTAssertTrue(store.onboardingCompletedSteps.isEmpty)
    }
}
