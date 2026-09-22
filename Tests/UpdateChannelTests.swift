import XCTest
@testable import Uncoil

final class UpdateChannelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "UncoilUpdateChannelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testExistingAndUnknownPreferencesUseStable() {
        XCTAssertEqual(UpdateChannelPreference(defaults: defaults).channel, .stable)
        defaults.set("unknown", forKey: UpdateChannelPreference.key)
        XCTAssertEqual(UpdateChannelPreference(defaults: defaults).channel, .stable)
    }

    func testSwitchingPersistsBothDirections() {
        let preference = UpdateChannelPreference(defaults: defaults)
        XCTAssertTrue(preference.select(.edge, sessionInProgress: false))
        XCTAssertEqual(UpdateChannelPreference(defaults: defaults).channel, .edge)
        XCTAssertTrue(preference.select(.stable, sessionInProgress: false))
        XCTAssertEqual(UpdateChannelPreference(defaults: defaults).channel, .stable)
    }

    func testActiveSessionCannotChangePreference() {
        let preference = UpdateChannelPreference(defaults: defaults)
        XCTAssertFalse(preference.select(.edge, sessionInProgress: true))
        XCTAssertEqual(preference.channel, .stable)
        XCTAssertNil(defaults.string(forKey: UpdateChannelPreference.key))
    }

    func testUnchangedChannelDoesNotStartAnotherCycle() {
        XCTAssertFalse(UpdateChannelPreference(defaults: defaults).select(.stable, sessionInProgress: false))
    }

    func testStableFeedRemainsCompatibleAndEdgeIsSeparate() {
        XCTAssertEqual(UpdateChannel.stable.feedURL.absoluteString, "https://uncoil.gokhantopbas.com/appcast.xml")
        XCTAssertEqual(UpdateChannel.edge.feedURL.absoluteString, "https://uncoil.gokhantopbas.com/appcast-edge.xml")
    }

    @MainActor
    func testFixtureSelectionPersistsWithoutStartingSparkle() {
        let updater = UpdaterService(defaults: defaults, startUpdater: false)
        updater.selectChannel(.edge)
        XCTAssertEqual(updater.channel, .edge)
        XCTAssertFalse(updater.isAvailable)
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertEqual(UpdaterService(defaults: defaults, startUpdater: false).channel, .edge)
    }
}
