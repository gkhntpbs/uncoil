import Foundation

struct ManagedRunRecord: Codable {
    var sessionID: UUID
    var project: Project
    var configID: String
    var name: String
    var ports: [Int]
    var previewURL: String?
    var quitBehavior: RunQuitBehavior
    var startedAt: Date
    var logURL: URL?
    var historyID: String?
}

final class SupervisedRunHandle: RunProcessHandle {
    let sessionID: UUID
    private let client: RuntimeClient
    private(set) var isRunning = true
    var pid: Int32 { client.processID(sid: sessionID) ?? 0 }

    init(sessionID: UUID, client: RuntimeClient) {
        self.sessionID = sessionID
        self.client = client
    }

    func didExit() { isRunning = false }
    func terminate() { client.terminateOwnedSession(sid: sessionID) }
    func forceKill() { client.terminateOwnedSession(sid: sessionID) }
    func sendInput(_ data: Data) {
        guard isRunning else { return }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r")
        client.sendInput(Data(text.utf8), sid: sessionID)
    }
}

@MainActor
enum RunSupervisor {
    static let client = RuntimeClient(
        socketPath: ProjectStore.defaultDirectory()
            .appendingPathComponent("run-supervisor/runtime.sock").path,
        daemonURL: RuntimeClient.defaultDaemonURL,
        observesWorkspaceNotifications: true
    )

    static func waitUntilReady() async -> Bool {
        client.start()
        let deadline = Date.now.addingTimeInterval(8)
        while !client.connectionIsReady(), Date.now < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return client.supportsManagedRuns() && !Task.isCancelled
    }
}
