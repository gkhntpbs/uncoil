import XCTest
@testable import Uncoil

/// Three sources disagree about "which model is this session using": what the
/// agent reports, what the user picked, and what the provider defaults to. The
/// status bar shows one of them, and a confidently wrong model is worse than an
/// honest blank — so the order, and the refusal to guess, are the tests.
final class SessionRuntimeInfoTests: XCTestCase {
    func testTheAgentsOwnReportWins() {
        let info = SessionRuntimeInfo.resolve(
            reportedModel: "opus",
            selection: AgentLaunchSelection(model: "sonnet"),
            defaultModelDetail: "haiku"
        )
        XCTAssertEqual(info.model, "opus")
        XCTAssertEqual(info.modelSource, .reported)
    }

    func testWhatTheUserPickedBeatsTheDefault() {
        let info = SessionRuntimeInfo.resolve(
            reportedModel: nil,
            selection: AgentLaunchSelection(model: "sonnet"),
            defaultModelDetail: "haiku"
        )
        XCTAssertEqual(info.model, "sonnet")
        XCTAssertEqual(info.modelSource, .chosen)
    }

    func testTheProviderDefaultIsTheLastResort() {
        let info = SessionRuntimeInfo.resolve(
            reportedModel: nil, selection: nil, defaultModelDetail: "gpt-5-codex"
        )
        XCTAssertEqual(info.model, "gpt-5-codex")
        XCTAssertEqual(info.modelSource, .providerDefault)
    }

    /// Nothing known means nothing shown. An empty chip is honest; a made-up
    /// model name is not.
    func testNothingKnownShowsNothing() {
        let info = SessionRuntimeInfo.resolve(
            reportedModel: nil, selection: nil, defaultModelDetail: nil
        )
        XCTAssertNil(info.model)
        XCTAssertNil(info.summary)
        XCTAssertNil(info.help)
    }

    func testEmptyStringsCountAsUnknown() {
        let info = SessionRuntimeInfo.resolve(
            reportedModel: "",
            selection: AgentLaunchSelection(model: "", effort: ""),
            defaultModelDetail: "sonnet"
        )
        XCTAssertEqual(info.model, "sonnet")
        XCTAssertNil(info.effort)
    }

    /// No agent puts its effort in a hook payload, so effort is what the user
    /// chose or nothing at all. Falling back to a provider default here would
    /// be inventing a number.
    func testEffortIsOnlyEverWhatWasChosen() {
        let chosen = SessionRuntimeInfo.resolve(
            reportedModel: "opus",
            selection: AgentLaunchSelection(model: nil, effort: "high"),
            defaultModelDetail: nil
        )
        XCTAssertEqual(chosen.effort, "high")
        XCTAssertEqual(chosen.effortSource, .chosen)

        let unset = SessionRuntimeInfo.resolve(
            reportedModel: "opus", selection: nil, defaultModelDetail: nil
        )
        XCTAssertNil(unset.effort)
    }

    func testTheSummaryIsBothValuesWhenBothAreKnown() {
        let info = SessionRuntimeInfo.resolve(
            reportedModel: "opus",
            selection: AgentLaunchSelection(model: nil, effort: "xhigh"),
            defaultModelDetail: nil
        )
        XCTAssertEqual(info.summary, "opus · xhigh")
    }

    /// The chip is short; the hover is where "you picked this" is told apart
    /// from "this is merely the default".
    func testTheHelpSaysWhereEachValueCameFrom() {
        let info = SessionRuntimeInfo.resolve(
            reportedModel: nil, selection: nil, defaultModelDetail: "gpt-5-codex"
        )
        let help = try? XCTUnwrap(info.help)
        XCTAssertEqual(help?.contains("gpt-5-codex"), true)
        XCTAssertEqual(help?.contains("default"), true)
    }
}
