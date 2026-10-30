import SwiftUI

struct MenuBarRunsSection: View {
    let activateMainWindow: () -> Void
    @ObservedObject private var registry = RunRegistry.shared
    @State private var busy = false

    var body: some View {
        if !registry.activeRuns.isEmpty {
            Text("Project Processes")
            ForEach(registry.activeRuns, id: \.sessionID) { record in
                Menu(label(record)) {
                    let state = registry.state(project: record.project, configID: record.configID)
                    Text(state.status.label)
                    if let issue = state.issue { Text(issue.hint) }
                    Button("Open Project") {
                        Router.shared.go(to: .project(record.project.id))
                        activateMainWindow()
                    }
                    if let url = previewURL(record) {
                        Button("Open URL") { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                    Button("Restart") {
                        perform {
                            _ = await registry.restart(project: record.project, configID: record.configID)
                        }
                    }
                    .disabled(busy)
                    Button("Stop") {
                        perform { await registry.stop(project: record.project, configID: record.configID) }
                    }
                    .disabled(busy)
                }
            }
            Button("Stop All Project Processes") {
                perform { await registry.stopAll() }
            }
            .disabled(busy)
            Divider()
        }
    }

    private func perform(_ action: @escaping @MainActor () async -> Void) {
        busy = true
        Task { @MainActor in
            await action()
            busy = false
        }
    }

    private func label(_ record: ManagedRunRecord) -> String {
        let state = registry.state(project: record.project, configID: record.configID)
        let ports = record.ports.map { ":\($0)" }.joined(separator: ", ")
        return "\(record.project.name) › \(record.name) — \(state.status.label) \(ports)"
    }

    private func previewURL(_ record: ManagedRunRecord) -> URL? {
        let address = record.previewURL ?? record.ports.first.map { "http://localhost:\($0)" }
        guard let address, let url = URL(string: address),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }
}
