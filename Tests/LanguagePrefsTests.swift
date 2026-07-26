import XCTest
@testable import Uncoil

final class LanguagePrefsTests: XCTestCase {
    func testSystemInterfaceFollowsPreferredLanguages() {
        let prefs = LanguagePrefs()
        XCTAssertEqual(prefs.resolvedInterface(preferredLanguages: ["tr-TR", "en-US"]), .turkish)
        XCTAssertEqual(prefs.resolvedInterface(preferredLanguages: ["en-GB"]), .english)
    }

    /// A language Uncoil does not ship falls back to English rather than to the
    /// system's raw preference, so no screen is left half-untranslated.
    func testUnshippedSystemLanguageResolvesToEnglish() {
        let prefs = LanguagePrefs()
        XCTAssertEqual(prefs.resolvedInterface(preferredLanguages: ["de-DE"]), .english)
    }

    func testExplicitInterfaceWinsOverSystem() {
        var prefs = LanguagePrefs(interface: .turkish)
        XCTAssertEqual(prefs.resolvedInterface(preferredLanguages: ["en-US"]), .turkish)
        prefs.interface = .english
        XCTAssertEqual(prefs.resolvedInterface(preferredLanguages: ["tr-TR"]), .english)
    }

    func testAgentLanguageFollowsInterfaceByDefault() {
        let prefs = LanguagePrefs(interface: .turkish)
        XCTAssertEqual(prefs.resolvedAgent(preferredLanguages: ["en-US"]), .turkish)
    }

    /// Reading the app in Turkish while agents answer in English is the whole
    /// reason the two settings are separate.
    func testAgentLanguageCanDivergeFromInterface() {
        let prefs = LanguagePrefs(interface: .turkish, agent: .english)
        XCTAssertEqual(prefs.resolvedInterface(preferredLanguages: ["tr-TR"]), .turkish)
        XCTAssertEqual(prefs.resolvedAgent(preferredLanguages: ["tr-TR"]), .english)
    }

    /// Prompts are authored in English, so English adds no directive at all —
    /// an agent should not be told to reply in the language it already sees.
    func testEnglishAddsNoDirective() {
        XCTAssertNil(PromptLanguage.english.directive)
        XCTAssertEqual(PromptLanguage.turkish.directive, "Reply in Türkçe.")
    }

    func testRelaunchOnlyNeededWhenTheRunningLanguageDiffers() {
        XCTAssertFalse(LanguagePrefs().needsRelaunch(currentLanguages: ["en"]))
        XCTAssertFalse(LanguagePrefs(interface: .turkish).needsRelaunch(currentLanguages: ["tr"]))
        XCTAssertTrue(LanguagePrefs(interface: .turkish).needsRelaunch(currentLanguages: ["en"]))
    }

    func testTaskPromptCarriesTheDirectiveOnlyForTurkish() {
        let document = TodoParser.parse("- [ ] ilk görev\n", path: "/repo/TODO.md")
        guard let task = document.tasks.first else { return XCTFail("no task parsed") }
        let project = Project(id: UUID(), name: "uncoil", rootPath: "/repo")

        func prompt(_ language: PromptLanguage) -> String {
            TaskPromptBuilder.prompt(TaskPromptBuilder.context(
                for: task, in: document, project: project, role: .implementer,
                worktreePath: nil, permissionProfile: [], language: language))
        }

        XCTAssertTrue(prompt(.turkish).contains("Reply in Türkçe."))
        XCTAssertFalse(prompt(.english).contains("Reply in"))
        // The prompt body itself never changes language.
        XCTAssertTrue(prompt(.turkish).contains("## Task"))
    }
}
