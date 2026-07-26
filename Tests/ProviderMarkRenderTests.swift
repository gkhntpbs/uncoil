import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders the agent marks offscreen, the way `ThemeSamplerRenderTests` renders
/// the palettes: a drawn shape is something to look at, not to assert about.
/// Set `UNCOIL_MARK_SAMPLE_DIR` to write the PNG somewhere.
@MainActor
final class ProviderMarkRenderTests: XCTestCase {
    private struct Sampler: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach([AgentProvider.claude, .codex, .terminal], id: \.self) { provider in
                    HStack(alignment: .center, spacing: 16) {
                        Text(provider.displayName)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.textDim)
                            .frame(width: 70, alignment: .leading)
                        // The sizes the marks are actually used at, plus one
                        // large enough to see what the shape really is.
                        ForEach([13, 17, 24, 48], id: \.self) { size in
                            ProviderMark(provider: provider, size: CGFloat(size))
                        }
                    }
                }
            }
            .padding(20)
            .frame(width: 320, alignment: .leading)
            .background(Theme.bg)
        }
    }

    func testMarksRender() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_MARK_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_MARK_SAMPLE_DIR to write provider mark samples")
        }
        let host = NSHostingView(rootView: Sampler())
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 190)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("marks.png"))
    }
}
