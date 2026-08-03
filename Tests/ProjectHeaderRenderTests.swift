import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders the reworked project header offscreen. Set
/// `UNCOIL_HEADER_SAMPLE_DIR` to write the PNG.
///
/// The header is what broke the window: its minimum width was the sum of the
/// tab row, the branch badge, the editor button and the launcher strip, none of
/// which would compress. When that exceeded the window, the whole split
/// overflowed and the sidebar was pushed off the left edge. The sample is drawn
/// at a deliberately tight width for that reason.
///
/// The launcher strip is gone from this screen entirely — it lives on the
/// sidebar's project rows and on the worktree rows, where it can say *which*
/// tree to start in.
@MainActor
final class ProjectHeaderRenderTests: XCTestCase {
    /// Mirrors the header's layout, so the arrangement can be looked at without
    /// a store, a git snapshot and a page cache behind it.
    private struct Sampler: View {
        let name: String
        let branch: String
        let areas: [ProjectArea]
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    ProjectIcon(project: Project(name: name, rootPath: "/tmp/\(name)"), size: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(Theme.mono(.title, .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            BranchBadge(branch: branch, isCompact: true)
                            Text("~/Developer/Projects/\(name)")
                                .font(Theme.mono(.body))
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .layoutPriority(-1)
                    Spacer(minLength: 8)
                    tabs
                    TablerIcon(name: "external-link", size: 12, color: Theme.textFaint)
                        .frame(width: 22, height: 22)
                        .padding(3)
                        .background(
                            Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                }
                .padding(14)
                .panel()
            }
            .padding(16)
            .frame(width: width, alignment: .leading)
            .background(Theme.bg)
        }

        private var tabs: some View {
            HStack(spacing: 2) {
                ForEach(areas) { area in
                    HStack(spacing: 6) {
                        TablerIcon(name: area.iconName, size: 12, color: Theme.textFaint)
                        Text(area.title)
                            .font(Theme.mono(.body))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
            .padding(3)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .fixedSize()
        }
    }

    func testTheProjectHeaderRenders() throws {
        guard let output = ProcessInfo.processInfo
            .environment["UNCOIL_HEADER_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_HEADER_SAMPLE_DIR to write the header sample")
        }
        let width: CGFloat = 900
        let stack = VStack(alignment: .leading, spacing: 0) {
            // A fully equipped project: the worst case for the tab row.
            Sampler(
                name: "midyanet", branch: "feat/design-kit",
                areas: [.overview, .tasks, .run, .tests, .issues], width: width
            )
            // And a bare folder, which is the common case and should be quiet.
            Sampler(
                name: "notes", branch: "main",
                areas: [.overview], width: width
            )
        }
        .frame(width: width)
        .background(Theme.bg)

        let host = NSHostingView(rootView: stack)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("header.png"))
    }
}
