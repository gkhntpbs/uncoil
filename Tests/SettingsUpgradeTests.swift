import XCTest
@testable import Uncoil

@MainActor
final class SettingsUpgradeTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testFutureAccountDoesNotResetSettingsOrOnboardingAndSurvivesSave() throws {
        let root = try directory()
        let account = AccountProfile(provider: .codex, name: "Work", directoryName: "work")
        var persisted = SettingsStore.Persisted()
        persisted.accounts = [account]
        persisted.onboardingVersion = OnboardingFlow.currentVersion
        persisted.onboardingCompletedSteps = ["accounts", "project"]
        persisted.preferredEditor = .zed
        persisted.defaultAccountByProvider = ["codex": account.id]
        let encoded = try JSONEncoder().encode(persisted)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        var future = try XCTUnwrap(accounts.first)
        future["provider"] = "future-agent"
        future["id"] = UUID().uuidString
        accounts.append(future)
        object["accounts"] = accounts
        object["futureSetting"] = ["enabled": true]
        let original = try JSONSerialization.data(withJSONObject: object)
        let file = root.appendingPathComponent("settings.json")
        try original.write(to: file)
        let store = SettingsStore(directory: root)
        XCTAssertEqual(store.preferredEditor, .zed)
        XCTAssertFalse(store.shouldPresentOnboarding)
        XCTAssertEqual(store.defaultAccount(for: .codex)?.id, account.id)
        store.preferredEditor = .xcode
        store.save()
        let reloaded = SettingsStore(directory: root)
        XCTAssertEqual(reloaded.preferredEditor, .xcode)
        XCTAssertFalse(reloaded.shouldPresentOnboarding)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((saved["futureSetting"] as? [String: Bool])?["enabled"], true)
        XCTAssertTrue((saved["accounts"] as? [[String: Any]])?.contains { $0["provider"] as? String == "future-agent" } == true)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings-before-migration-") }
        XCTAssertFalse(backups.isEmpty)
        XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == original })
    }

    func testMissingLegacyFieldsAndUnsupportedPreferencePreserveOtherValues() throws {
        let root = try directory()
        let object: [String: Any] = ["preferredEditor": "future-editor", "onboardingVersion": OnboardingFlow.currentVersion, "optionAsMetaKey": true]
        let file = root.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let store = SettingsStore(directory: root)
        XCTAssertTrue(store.optionAsMetaKey)
        XCTAssertFalse(store.shouldPresentOnboarding)
        store.save()
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["preferredEditor"] as? String, "future-editor")
        store.preferredEditor = .zed
        store.save()
        XCTAssertEqual(SettingsStore(directory: root).preferredEditor, .zed)
    }

    func testCorruptSettingsAreNeverOverwrittenByStartupOrSave() throws {
        let root = try directory()
        let file = root.appendingPathComponent("settings.json")
        let original = Data("{broken settings".utf8)
        try original.write(to: file)
        let store = SettingsStore(directory: root)
        store.save()
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
