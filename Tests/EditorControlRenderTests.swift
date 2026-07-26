import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders the editor-open control offscreen so its menu chevron can be looked
/// at. Set `UNCOIL_EDITOR_SAMPLE_DIR` to write the PNG.
@MainActor
final class EditorControlRenderTests: XCTestCase {
    func testControlRenders() throws {
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_EDITOR_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_EDITOR_SAMPLE_DIR to write the editor control sample")
        }
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uncoil-editor-\(UUID().uuidString)")
        let settings = SettingsStore(directory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let view = HStack(spacing: 12) {
            EditorOpenControl(directory: NSTemporaryDirectory())
                .padding(3)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1)
                )
            BranchBadge(branch: "main")
        }
        .padding(20)
        .background(Theme.bg)
        .environmentObject(settings)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 70)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("editor.png"))
    }
}
