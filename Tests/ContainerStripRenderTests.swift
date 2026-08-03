import AppKit
import SwiftUI
import XCTest
@testable import Uncoil

/// Renders the container strip offscreen, the way `ProviderMarkRenderTests`
/// renders the agent marks. Set `UNCOIL_DOCKER_SAMPLE_DIR` to write the PNG.
///
/// The strip is drawn inside `RunConfigurationRow`, which is private and needs a
/// registry and a project; this mirrors its layout so the wording and the dot
/// colours can be looked at without one.
@MainActor
final class ContainerStripRenderTests: XCTestCase {
    private struct Sampler: View {
        let groups: [(title: String, containers: [DockerContainer])]

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.title) { group in
                    let health = DockerStatus.health(of: group.containers)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.title)
                            .font(Theme.mono(.small, .semibold))
                            .foregroundStyle(Theme.text)
                        Text(health.label)
                            .font(Theme.mono(.micro, .semibold))
                            .foregroundStyle(health.isDegraded ? Theme.warn : Theme.textDim)
                        ForEach(group.containers) { container in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(color(container))
                                    .frame(width: 5, height: 5)
                                Text(container.service.isEmpty
                                     ? container.name : container.service)
                                    .font(Theme.mono(.micro))
                                    .foregroundStyle(Theme.textDim)
                                Text(container.health.isEmpty
                                     ? container.state
                                     : "\(container.state) · \(container.health)")
                                    .font(Theme.mono(.micro))
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(width: 420, alignment: .leading)
            .background(Theme.panel)
        }

        private func color(_ container: DockerContainer) -> Color {
            if container.isRestarting || container.isUnhealthy { return Theme.warn }
            return container.isRunning ? Theme.ok : Theme.textFaint
        }
    }

    func testTheContainerStripRenders() throws {
        guard let directory = ProcessInfo.processInfo
            .environment["UNCOIL_DOCKER_SAMPLE_DIR"] else {
            throw XCTSkip("Set UNCOIL_DOCKER_SAMPLE_DIR to write the container strip sample")
        }
        let sampler = Sampler(groups: [
            ("All healthy", [
                DockerContainer(name: "shop-web-1", service: "web", state: "running", health: "healthy"),
                DockerContainer(name: "shop-db-1", service: "db", state: "running", health: ""),
            ]),
            ("A container crash-looping while compose stays alive", [
                DockerContainer(name: "shop-web-1", service: "web", state: "running", health: ""),
                DockerContainer(name: "shop-worker-1", service: "worker", state: "restarting", health: ""),
            ]),
            ("Unhealthy, and one stopped", [
                DockerContainer(name: "shop-web-1", service: "web", state: "running", health: "unhealthy"),
                DockerContainer(name: "shop-cache-1", service: "cache", state: "exited", health: ""),
            ]),
        ])
        let host = NSHostingView(rootView: sampler)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("containers.png")
        )
    }
}
