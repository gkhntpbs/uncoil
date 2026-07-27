import Foundation

/// Task counts the menu bar shows next to the session counts.
///
/// Derived from Attention Center rows rather than from a second source of
/// truth, so the menu and the panel can never disagree.
struct MenuBarTaskCounts: Equatable {
    var running = 0
    var queued = 0
    var blocked = 0
    var awaitingReview = 0
    var completed = 0
    var mergeReady = 0

    var total: Int { running + queued + blocked + awaitingReview + completed }
    var isEmpty: Bool { total + mergeReady == 0 }

    init() {}

    init(attention: [AttentionItem]) {
        for item in attention {
            switch item.kind {
            case .taskAssigned: running += 1
            case .taskBlocked, .changesRequested: blocked += 1
            case .reviewRequested: awaitingReview += 1
            case .taskCompleted: completed += 1
            case .mergeReady: mergeReady += 1
            default: break
            }
        }
    }

    /// Queued work is not an attention row — nothing is waiting on the user —
    /// so the count comes from the orchestrator's own view.
    mutating func setQueued(_ count: Int) { queued = count }

    var headline: String {
        var parts: [String] = []
        if running > 0 { parts.append("\(running) tasks running") }
        if queued > 0 { parts.append("\(queued) queued") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if awaitingReview > 0 { parts.append("\(awaitingReview) awaiting review") }
        if completed > 0 { parts.append("\(completed) done") }
        if mergeReady > 0 { parts.append("\(mergeReady) ready to merge") }
        return parts.joined(separator: " · ")
    }
}

/// What the menu-bar monitor reports at a glance.
struct MenuBarSummary: Equatable {
    var running = 0
    var waitingPermission = 0
    var waitingInput = 0
    var completed = 0
    /// Runtime trouble, failing tests and logins — anything that is a problem
    /// rather than a normal wait.
    var problems = 0
    var tasks = MenuBarTaskCounts()

    var hasProblem: Bool { problems > 0 }
    var needsUser: Bool { waitingPermission > 0 || waitingInput > 0 }

    /// One-line summary for the top of the menu.
    var headline: String {
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if waitingPermission > 0 { parts.append("\(waitingPermission) waiting for permission") }
        if waitingInput > 0 { parts.append("\(waitingInput) waiting for a reply") }
        if completed > 0 { parts.append("\(completed) done") }
        if problems > 0 { parts.append("\(problems) problems") }
        return parts.isEmpty ? "Nothing pending" : parts.joined(separator: " · ")
    }

    /// Second line of the menu: tasks, when there are any.
    var taskHeadline: String? {
        tasks.isEmpty ? nil : tasks.headline
    }

    /// SF Symbol for the menu-bar icon; escalates with urgency.
    /// Which of the three menu-bar logos to show. One glance, three answers:
    /// yellow = something waits on the user (input, permission, or a problem),
    /// color = agents are working, plain = nothing is happening.
    enum Icon: String, Equatable {
        /// Template asset: the system renders it white on a dark menu bar.
        case idle = "MenuBarIconTemplate"
        case working = "MenuBarIconColor"
        case waiting = "MenuBarIconWaiting"

        /// SF Symbol equivalent, for users who prefer a system glyph to the
        /// mark. Same three-state reading, drawn in the menu bar's own colour.
        var symbolName: String {
            switch self {
            case .idle: "circle.dotted"
            case .working: "circle.hexagongrid.circle"
            case .waiting: "exclamationmark.circle"
            }
        }
    }

    var icon: Icon {
        if waitingPermission > 0 || waitingInput > 0 || hasProblem { return .waiting }
        if running > 0 { return .working }
        return .idle
    }
}

/// Pure derivation of the menu-bar summary, so counting rules are testable
/// without a running app.
enum MenuBarMonitorEngine {
    static func summary(
        statuses: [UUID: AgentSessionStatus],
        attention: [AttentionItem] = [],
        queuedTasks: Int = 0
    ) -> MenuBarSummary {
        var summary = MenuBarSummary()
        for status in statuses.values {
            switch status {
            case .running, .thinking:
                summary.running += 1
            case .waitingForPermission:
                summary.waitingPermission += 1
            case .waitingForInput:
                summary.waitingInput += 1
            case .completed:
                summary.completed += 1
            case .idle, .terminated:
                break
            }
        }
        summary.problems = attention.filter(\.kind.isProblem).count
        summary.tasks = MenuBarTaskCounts(attention: attention)
        summary.tasks.setQueued(queuedTasks)
        return summary
    }

    /// Sessions the monitor offers a one-click interrupt for.
    static func interruptible(
        _ sessions: [SessionRecord],
        statuses: [UUID: AgentSessionStatus]
    ) -> [SessionRecord] {
        sessions.filter {
            switch statuses[$0.id] {
            case .running, .thinking, .waitingForPermission, .waitingForInput:
                true
            default:
                false
            }
        }
    }
}
