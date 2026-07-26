import Darwin
import Foundation

/// Health of one MCP extension's processes, derived from the run records the
/// launcher writes. Uncoil does not own these processes — the agent started
/// them — so supervision is observation plus explicit user actions, never a
/// silent restart.
struct MCPProcessHealth: Identifiable, Equatable {
    enum State: String, Equatable {
        case running
        case stopped
        case crashed
        /// Repeated crashes in a short window: restarting again would just
        /// repeat the failure.
        case crashLoop
        case neverStarted

        var label: String {
            switch self {
            case .running: String(localized: "Running")
            case .stopped: String(localized: "Stopped")
            case .crashed: String(localized: "Crashed")
            case .crashLoop: String(localized: "Crashing repeatedly")
            case .neverStarted: String(localized: "Never started")
            }
        }
    }

    let id: String
    var state: State
    /// Agents that started a process for this extension.
    var startedByAgents: [String]
    var livePIDs: [Int32]
    var lastExitCode: Int32?
    var lastSignal: Int32?
    var crashCount: Int
    /// Live processes still running an older revision than the active one.
    var stalePIDs: [Int32]

    /// A running process on an old revision is what "Restart now" is for.
    var needsRestart: Bool { !stalePIDs.isEmpty }
    var isHealthy: Bool { state == .running || state == .stopped || state == .neverStarted }
}

/// Derives per-extension process health, detects crash loops, and performs the
/// two actions a user can take: graceful shutdown and restart-by-shutdown.
@MainActor
struct MCPProcessSupervisor {
    /// How many crashes inside `crashWindow` count as a loop.
    var crashLoopThreshold = 3
    var crashWindow: TimeInterval = 120
    /// Injected so tests do not depend on real processes.
    var isProcessAlive: (Int32) -> Bool = { pid in
        pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
    }
    var terminate: (Int32, Int32) -> Void = { pid, signalNumber in
        _ = kill(pid, signalNumber)
    }

    /// Health for one extension from its run records.
    func health(
        extensionID: String,
        records: [ExtensionRunRecord],
        activeRevisionID: String?,
        now: Date = .now
    ) -> MCPProcessHealth {
        let mine = records.filter { $0.extensionID == extensionID }
        guard !mine.isEmpty else {
            return MCPProcessHealth(
                id: extensionID, state: .neverStarted, startedByAgents: [],
                livePIDs: [], lastExitCode: nil, lastSignal: nil,
                crashCount: 0, stalePIDs: []
            )
        }
        // A record with no end time is only "running" if the process still is:
        // a killed launcher never gets to write its ending.
        let live = mine.filter { $0.isRunning && isProcessAlive($0.pid) }
        let recentCrashes = mine.filter {
            $0.crashed && ($0.endedAt ?? $0.startedAt) >= now.addingTimeInterval(-crashWindow)
        }
        let latest = mine.max { $0.startedAt < $1.startedAt }

        let state: MCPProcessHealth.State
        if recentCrashes.count >= crashLoopThreshold {
            state = .crashLoop
        } else if !live.isEmpty {
            state = .running
        } else if latest?.crashed == true {
            state = .crashed
        } else {
            state = .stopped
        }

        let stale = activeRevisionID.map { active in
            live.filter { $0.revisionID != nil && $0.revisionID != active }.map(\.pid)
        } ?? []

        return MCPProcessHealth(
            id: extensionID,
            state: state,
            startedByAgents: Array(Set(mine.compactMap(\.agent))).sorted(),
            livePIDs: live.map(\.pid).sorted(),
            lastExitCode: latest?.exitCode,
            lastSignal: latest?.signal,
            crashCount: recentCrashes.count,
            stalePIDs: stale.sorted()
        )
    }

    func healthByExtension(
        records: [ExtensionRunRecord],
        activeRevisions: [String: String],
        now: Date = .now
    ) -> [MCPProcessHealth] {
        Set(records.map(\.extensionID)).sorted().map { id in
            health(
                extensionID: id, records: records,
                activeRevisionID: activeRevisions[id], now: now
            )
        }
    }

    /// Asks the launcher to shut its child down cleanly; the agent will start a
    /// fresh one on its next call, which is how a "restart" happens without
    /// Uncoil owning the process.
    @discardableResult
    func shutdown(_ health: MCPProcessHealth, graceful: Bool = true) -> [Int32] {
        let signalNumber = graceful ? SIGTERM : SIGKILL
        for pid in health.livePIDs {
            terminate(pid, signalNumber)
        }
        return health.livePIDs
    }

    /// Stops only the processes still on an old revision, leaving current ones
    /// alone — the least disruptive way to finish an update.
    @discardableResult
    func retireStaleProcesses(_ health: MCPProcessHealth) -> [Int32] {
        for pid in health.stalePIDs {
            terminate(pid, SIGTERM)
        }
        return health.stalePIDs
    }

    /// Health-check rows for the Extensions Center.
    func checks(_ health: MCPProcessHealth, now: Date = .now) -> [HealthCheckResult] {
        var results: [HealthCheckResult] = [
            HealthCheckResult(
                id: "process.\(health.id)",
                name: "Process durumu",
                outcome: {
                    switch health.state {
                    case .running, .stopped, .neverStarted: .ok
                    case .crashed: .warning
                    case .crashLoop: .failure
                    }
                }(),
                detail: health.state.label,
                remedy: health.state == .crashLoop
                    ? "Look at the logs; do not restart until it is fixed."
                    : nil,
                checkedAt: now
            ),
        ]
        if health.needsRestart {
            results.append(HealthCheckResult(
                id: "process.\(health.id).stale",
                name: "Old revision",
                outcome: .warning,
                detail: "\(health.stalePIDs.count) processes are running an old revision.",
                remedy: "Move to the new revision with Restart now.",
                checkedAt: now
            ))
        }
        return results
    }
}
