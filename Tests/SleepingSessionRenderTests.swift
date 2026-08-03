import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders both sleeping screens offscreen, the way `ProviderMarkRenderTests`
/// renders the agent marks: the wording and the spacing are things to look at,
/// not to assert about. Set `UNCOIL_SLEEP_SAMPLE_DIR` to write the PNG.
@MainActor
final class SleepingSessionRenderTests: XCTestCase {
    private static func record(_ title: String) -> SessionRecord {
        var record = SessionRecord(
            projectID: UUID(), provider: .claude, accountID: nil, title: title
        )
        record.providerSessionID = "prov-1"
        record.sleptAt = Date(timeIntervalSinceNow: -1800)
        return record
    }

    private struct Sampler: View {
        let paused: SessionRecord
        let asleep: SessionRecord

        var body: some View {
            VStack(spacing: 12) {
                SleepingSessionView(record: paused, mode: .suspended) {}
                SleepingSessionView(record: asleep, mode: .hibernated) {}
            }
            .padding(16)
            .frame(width: 620, height: 620)
            .background(Theme.bg)
        }
    }

    func testTheSleepingScreensRender() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_SLEEP_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_SLEEP_SAMPLE_DIR to write the sleeping-session sample")
        }
        let host = NSHostingView(
            rootView: Sampler(
                paused: Self.record("claude: refactor"),
                asleep: Self.record("claude: parked")
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 620)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("sleeping.png")
        )
    }
}
