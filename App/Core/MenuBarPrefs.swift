import Foundation

/// Everything the menu-bar monitor lets the user decide: which icon, what the
/// text next to it counts, and which sections the drop-down carries.
struct MenuBarPrefs: Codable, Equatable, Sendable {
    /// What is drawn in the menu bar itself.
    enum IconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The Uncoil mark, which changes colour with state.
        case logo
        /// An SF Symbol that escalates with urgency — fits a busy menu bar.
        case symbol
        /// No glyph at all; only the counters.
        case countOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .logo: "Uncoil logosu"
            case .symbol: "System symbol"
            case .countOnly: "Counters only"
            }
        }

        var detail: String {
            switch self {
            case .logo: "The Uncoil mark, coloured by state."
            case .symbol: "A single-colour SF Symbol, which sits better in the menu bar."
            case .countOnly: "No icon; only the counters you picked are shown."
            }
        }
    }

    /// What a left click on the icon does.
    enum ClickAction: String, Codable, CaseIterable, Identifiable, Sendable {
        case openMenu
        case openMainWindow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openMenu: "Open the menu"
            case .openMainWindow: "Open the Uncoil window"
            }
        }
    }

    /// A counter that can appear next to the icon.
    enum Counter: String, Codable, CaseIterable, Identifiable, Sendable {
        case running
        case waiting
        case problems
        case tasks

        var id: String { rawValue }

        var title: String {
            switch self {
            case .running: "Running sessions"
            case .waiting: "Bekleyenler"
            case .problems: "Sorunlar"
            case .tasks: "Active tasks"
            }
        }

        /// Suffix that keeps the counters apart at a glance: `3 2! 1×`.
        var marker: String {
            switch self {
            case .running: ""
            case .waiting: "!"
            case .problems: "×"
            case .tasks: "⏱"
            }
        }

        func value(in summary: MenuBarSummary) -> Int {
            switch self {
            case .running: summary.running
            case .waiting: summary.waitingPermission + summary.waitingInput
            case .problems: summary.problems
            case .tasks: summary.tasks.total
            }
        }
    }

    var enabled = true
    var iconStyle: IconStyle = .logo
    /// Force a template (single-colour) rendering even for the logo.
    var monochrome = false
    var counters: Set<String> = [
        Counter.running.rawValue,
        Counter.waiting.rawValue,
        Counter.problems.rawValue,
    ]
    /// Hide the item entirely while nothing is happening.
    var hideWhenIdle = false
    var clickAction: ClickAction = .openMenu

    // Drop-down sections
    var showTasksSection = true
    var showSessionsSection = true
    var showQuickLaunch = true

    init() {}

    func shows(_ counter: Counter) -> Bool { counters.contains(counter.rawValue) }

    mutating func set(_ counter: Counter, enabled: Bool) {
        if enabled { counters.insert(counter.rawValue) } else { counters.remove(counter.rawValue) }
    }

    /// The text next to the icon. Empty when nothing is selected or everything
    /// is at zero, so the icon stands alone instead of showing a row of zeros.
    func label(for summary: MenuBarSummary) -> String {
        Counter.allCases
            .filter { shows($0) && $0.value(in: summary) > 0 }
            .map { "\($0.value(in: summary))\($0.marker)" }
            .joined(separator: " ")
    }

    /// Whether the status item should be in the menu bar at all right now.
    func isVisible(for summary: MenuBarSummary) -> Bool {
        guard enabled else { return false }
        guard hideWhenIdle else { return true }
        return summary.icon != .idle || !label(for: summary).isEmpty
    }

    /// Icon asset / symbol to draw, honouring the chosen style.
    func icon(for summary: MenuBarSummary) -> MenuBarIcon {
        switch iconStyle {
        case .countOnly:
            return .none
        case .symbol:
            return .symbol(summary.icon.symbolName)
        case .logo:
            return .asset(monochrome ? MenuBarSummary.Icon.idle.rawValue : summary.icon.rawValue)
        }
    }

    // MARK: - Codable
    //
    // Hand-written for the same reason as NotificationPrefs: a missing key must
    // fall back to the default instead of failing the whole settings decode.

    private enum CodingKeys: String, CodingKey {
        case enabled, iconStyle, monochrome, counters, hideWhenIdle, clickAction
        case showTasksSection, showSessionsSection, showQuickLaunch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MenuBarPrefs()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        iconStyle = try container.decodeIfPresent(IconStyle.self, forKey: .iconStyle)
            ?? fallback.iconStyle
        monochrome = try container.decodeIfPresent(Bool.self, forKey: .monochrome)
            ?? fallback.monochrome
        counters = try container.decodeIfPresent(Set<String>.self, forKey: .counters)
            ?? fallback.counters
        hideWhenIdle = try container.decodeIfPresent(Bool.self, forKey: .hideWhenIdle)
            ?? fallback.hideWhenIdle
        clickAction = try container.decodeIfPresent(ClickAction.self, forKey: .clickAction)
            ?? fallback.clickAction
        showTasksSection = try container.decodeIfPresent(Bool.self, forKey: .showTasksSection)
            ?? fallback.showTasksSection
        showSessionsSection = try container.decodeIfPresent(Bool.self, forKey: .showSessionsSection)
            ?? fallback.showSessionsSection
        showQuickLaunch = try container.decodeIfPresent(Bool.self, forKey: .showQuickLaunch)
            ?? fallback.showQuickLaunch
    }
}

/// What the menu-bar label draws, resolved from the prefs.
enum MenuBarIcon: Equatable, Sendable {
    case asset(String)
    case symbol(String)
    case none
}
