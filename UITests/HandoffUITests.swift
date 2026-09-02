import XCTest

/// Drives the handoff the way a person does, and asserts on what actually
/// moved rather than on what the sheet says about it.
///
/// Two lessons are built into its shape. First, the runner is sandboxed into
/// its own container and cannot read the app's files, so everything the test
/// needs to see — the submitted prompt, the handover file — is journalled by
/// the app into a path the *test* chooses inside its own container. Second,
/// the "ask the outgoing agent" step is left ON and answered by a stub the app
/// plants when launched with `-handoff-agent-stub`: switching the toggle off
/// kept the test cheap and quietly exempted the one step that had never been
/// exercised.
final class HandoffUITests: XCTestCase {
    private var app: XCUIApplication!
    private var journalURL: URL!

    override func setUp() {
        continueAfterFailure = false
        journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-journal-\(UUID().uuidString).log")
        app = XCUIApplication()
        app.launchEnvironment["UNCOIL_TEST_JOURNAL"] = journalURL.path
        app.launchArguments = [
            "-ui-testing", "-reset-state",
            "-fixture", "demo",
            "-route", "session",
            "-window-width", "1300", "-window-height", "850",
            "-disable-animations",
            // Value-less flags last on purpose: one placed before `-route`
            // leaves the app with no window at all.
            "-usage-fixture",
            "-handoff-agent-stub",
        ]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(at: journalURL)
    }

    private func journal() -> String {
        (try? String(contentsOf: journalURL, encoding: .utf8)) ?? ""
    }

    /// Low account → warning → destination → the outgoing agent is asked →
    /// a new session exists, was started, and was handed the opening line.
    func testHandoffReachesAnotherAgent() throws {
        let chip = app.descendants(matching: .any)["session.usageChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "usage chip never appeared")
        XCTAssertEqual(chip.value as? String, "8% remaining", "the seeded figure is not on screen")

        // From the header's control cluster: the usage card and the Attention
        // Center are popovers, and a popover's contents never appear in the
        // app's accessibility tree.
        let handoff = app.descendants(matching: .any)["session.handoffButton"]
        XCTAssertTrue(
            handoff.waitForExistence(timeout: 15),
            "no handoff button in the header — the account is not being read as low"
        )
        handoff.click()

        let sheet = app.descendants(matching: .any)
            .matching(identifier: "handoff.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the handoff sheet never opened")

        // The ask-agent toggle stays ON; the stub answers for the CLI.
        let destination = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "handoff.destination."))
            .firstMatch
        XCTAssertTrue(
            destination.waitForExistence(timeout: 5),
            "no destination was offered — no second agent is installed"
        )
        destination.click()

        let openIt = app.descendants(matching: .any)["handoff.open"]
        XCTAssertTrue(openIt.waitForExistence(timeout: 90), "the handoff never finished")

        // The stub answered, so the completion must say the notes went along —
        // this is the assertion the toggle used to exempt.
        let outcome = app.descendants(matching: .any)["handoff.outcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 5), "no outcome line")
        let outcomeText = (outcome.value as? String) ?? outcome.label
        XCTAssertTrue(
            outcomeText.contains("previous agent's notes"),
            "the agent's half did not make it through the ask path: \(outcomeText)"
        )

        openIt.click()
        XCTAssertFalse(
            openIt.waitForExistence(timeout: 5),
            "the sheet stayed up after the handoff finished"
        )

        // What the app journalled: the handover file was written, and the
        // opening line was submitted into the new session's terminal. The
        // journal exists because neither is visible to accessibility queries —
        // a handoff that delivered nothing once passed this test.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !journal().contains("SUBMIT") {
            Thread.sleep(forTimeInterval: 1)
        }
        let events = journal()
        XCTAssertTrue(events.contains("HANDOVER\t"), "no handover file was written: \(events)")
        XCTAssertTrue(
            events.contains("SUBMIT") && events.contains(".uncoil/handoff/"),
            "the opening line never reached the new session — journal: \(events)"
        )
        // The handover carries the stub's half, proving ask → parse → merge →
        // file, not only that a file appeared. Checked through the journal —
        // the file itself is outside this runner's sandbox.
        let handover = events
            .components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("HANDOVER-TEXT\t") }) ?? ""
        XCTAssertTrue(
            handover.contains("Finish the demo feature"),
            "the outgoing agent's notes are not in the handover: \(handover.prefix(400))"
        )
    }
}
