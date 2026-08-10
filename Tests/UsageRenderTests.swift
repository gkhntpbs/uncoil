import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders the usage chip and its card offscreen so they can be looked at.
///
/// Offscreen rather than from a screenshot of the running app, for two reasons
/// that both matter. A popover only exists while it is open, so photographing
/// one means driving the app; and a figure only exists when an account has one,
/// so the states worth checking — nearly exhausted, stale, refused — are the
/// ones hardest to arrange on a real machine. Here they are arguments.
///
/// Set `UNCOIL_USAGE_SAMPLE_DIR` to write the PNGs.
@MainActor
final class UsageRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func write(_ view: some View, size: NSSize, named name: String, into directory: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// Every band of the ring side by side, which is the only way to see that
    /// they are actually distinguishable at the size they are drawn.
    func testRingBandsRender() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_USAGE_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_USAGE_SAMPLE_DIR to write the usage samples")
        }
        let view = HStack(spacing: 18) {
            ForEach(
                [("82", 82.0, UsageDisplay.Severity.healthy),
                 ("31", 31.0, .low),
                 ("8", 8.0, .critical),
                 ("0", 0.0, .critical)],
                id: \.0
            ) { label, value, severity in
                HStack(spacing: 5) {
                    UsageRing(remainingPercent: value, severity: severity)
                    Text("\(label)%")
                        .font(Theme.mono(.body, .medium))
                        .foregroundStyle(severity.color)
                }
            }
            HStack(spacing: 5) {
                UsageRing(remainingPercent: 47, severity: .low, stale: true)
                Text(verbatim: "47%")
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.textFaint)
            }
            HStack(spacing: 5) {
                UsageRing(remainingPercent: nil, severity: .unknown)
                Text(verbatim: "—")
                    .font(Theme.mono(.body, .medium))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(20)
        .background(Theme.bg)

        try write(view, size: NSSize(width: 560, height: 60), named: "usage-rings.png", into: directory)
    }

    /// The card with real windows, in the state the feature exists for: a
    /// comfortable session, a tight week and a model that is nearly gone.
    func testCardRenders() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_USAGE_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_USAGE_SAMPLE_DIR to write the usage samples")
        }
        var entry = UsageEntry()
        entry.snapshot = UsageFixture.snapshot(now: now)
        entry.refresh.lastSuccess = now.addingTimeInterval(-140)

        let card = UsageCard(
            provider: .claude,
            account: AccountProfile(provider: .claude, name: "Default"),
            entry: entry,
            now: now,
            onRefresh: {}
        )
        .background(Theme.bg)

        try write(card, size: NSSize(width: 300, height: 340), named: "usage-card.png", into: directory)
    }

    /// The stale card: the same numbers, kept because a refresh failed, saying
    /// so rather than looking current.
    func testStaleCardRenders() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_USAGE_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_USAGE_SAMPLE_DIR to write the usage samples")
        }
        var entry = UsageEntry()
        entry.snapshot = UsageFixture.snapshot(now: now.addingTimeInterval(-1_100))
            .markedStale(error: "timedOut")

        let card = UsageCard(
            provider: .claude,
            account: AccountProfile(provider: .claude, name: "Default"),
            entry: entry,
            now: now,
            onRefresh: {}
        )
        .background(Theme.bg)

        try write(card, size: NSSize(width: 300, height: 370), named: "usage-card-stale.png", into: directory)
    }

    /// The card with nothing to show. Four reasons, four sentences, because
    /// only two of them are the user's to fix and "usage unavailable" would
    /// send someone to check a login that is working perfectly well.
    func testUnavailableCardsRender() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_USAGE_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_USAGE_SAMPLE_DIR to write the usage samples")
        }
        let reasons: [(UsageUnavailability, AgentProvider)] = [
            (.noCredentials, .codex),
            (.credentialsRejected, .claude),
            (.accountTierUnsupported, .gemini),
            (.planReportsNoQuota, .claude),
        ]
        let stamp = now
        let view = VStack(spacing: 10) {
            ForEach(reasons, id: \.0) { reason, provider in
                var entry = UsageEntry()
                let _ = entry.snapshot = .unavailable(
                    provider: provider, reason: reason,
                    source: .cache, updatedAt: stamp.addingTimeInterval(-90)
                )
                UsageCard(
                    provider: provider, account: nil, entry: entry, now: stamp, onRefresh: {}
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.panel)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
            }
        }
        .padding(16)
        .background(Theme.bg)

        try write(view, size: NSSize(width: 332, height: 640), named: "usage-unavailable.png", into: directory)
    }
}
