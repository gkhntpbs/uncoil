import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders the Issues screen offscreen. Set `UNCOIL_ISSUES_SAMPLE_DIR` to write
/// the PNG.
///
/// Two repositories on purpose: the layout has to make it obvious that `#1` from
/// one repo is not `#1` from the other.
@MainActor
final class IssuesViewRenderTests: XCTestCase {
    private struct Sampler: View {
        let issues: [GitHubIssue]

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("ISSUES")
                        .font(Theme.mono(.micro, .semibold))
                        .foregroundStyle(Theme.textFaint)
                    Text("\(issues.count)")
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                    Text("owner/app · owner/api")
                        .font(Theme.mono(.micro))
                        .foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                ForEach(issues) { issue in
                    card(issue)
                }
            }
            .padding(16)
            .frame(width: 760, alignment: .leading)
            .background(Theme.bg)
        }

        private func card(_ issue: GitHubIssue) -> some View {
            HStack(alignment: .top, spacing: 8) {
                TablerIcon(name: "circle-dot", size: 12, color: Theme.ok)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(Theme.mono(.body))
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        Text("\(issue.repository)#\(issue.number)")
                        Text(issue.author)
                        if issue.commentCount > 0 { Text("\(issue.commentCount) comments") }
                    }
                    .font(Theme.mono(.micro))
                    .foregroundStyle(Theme.textFaint)
                    if !issue.labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(issue.labels) { label in
                                Text(label.name)
                                    .font(Theme.mono(.micro))
                                    .foregroundStyle(Theme.textDim)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Color(hexString: label.color).opacity(0.22), in: Capsule()
                                    )
                            }
                        }
                    }
                }
                Spacer(minLength: 6)
            }
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
    }

    private func issue(
        _ number: Int, repository: String, title: String,
        labels: [(String, String)], comments: Int
    ) -> GitHubIssue {
        GitHubIssue(
            apiID: number, number: number, title: title, body: "",
            author: "ada", state: "open",
            labels: labels.map { GitHubIssue.Label(name: $0.0, color: $0.1) },
            assignees: [], commentCount: comments, updatedAt: Date(),
            htmlURL: nil, repository: repository
        )
    }

    func testTheIssuesScreenRenders() throws {
        guard let output = ProcessInfo.processInfo
            .environment["UNCOIL_ISSUES_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_ISSUES_SAMPLE_DIR to write the Issues sample")
        }
        let sampler = Sampler(issues: [
            issue(1, repository: "owner/app", title: "Crash when opening a worktree session",
                  labels: [("bug", "d73a4a"), ("needs-triage", "fbca04")], comments: 3),
            issue(1, repository: "owner/api", title: "Rate limit the issues endpoint",
                  labels: [("enhancement", "a2eeef")], comments: 0),
            issue(28, repository: "owner/app", title: "Document the MCP capability grants",
                  labels: [("documentation", "0075ca")], comments: 12),
        ])
        let host = NSHostingView(rootView: sampler)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 330)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("issues.png"))
    }
}
