import Foundation

enum QuotaOptimizationMode: String, Codable, CaseIterable, Identifiable {
    case notifyOnly
    case preferUnusedQuota
    case ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifyOnly: String(localized: "Notify only")
        case .preferUnusedQuota: String(localized: "Prefer unused quota")
        case .ignore: String(localized: "Ignore unused quota")
        }
    }
}

struct QuotaOptimizationPrefs: Codable, Equatable {
    var mode: QuotaOptimizationMode = .notifyOnly
    var resetWithinHours = 24
    var minimumUnusedPercent = 20
}

struct QuotaForecast: Equatable {
    let key: UsageKey
    let window: UsageWindow
    let updatedAt: Date
    let burnRatePerHour: Double?
    let projectedUnusedPercent: Double?

    var remainingPercent: Int { Int(window.remainingPercent.rounded(.down)) }
    var unusedPercent: Double { projectedUnusedPercent ?? window.remainingPercent }

    func isOpportunity(_ prefs: QuotaOptimizationPrefs, now: Date) -> Bool {
        guard prefs.mode != .ignore, let reset = window.resetsAt,
              reset > now, reset.timeIntervalSince(now) <= Double(prefs.resetWithinHours) * 3_600,
              now.timeIntervalSince(updatedAt) >= 0, now.timeIntervalSince(updatedAt) <= 90 * 60 else { return false }
        return unusedPercent >= Double(prefs.minimumUnusedPercent)
    }

    func detail(now: Date) -> String {
        let reset = UsageDisplay.resetLine(window, now: now) ?? ""
        if let projectedUnusedPercent {
            let percent = Int(projectedUnusedPercent.rounded(.down))
            return String(localized: "At the recent pace, \(percent)% of your weekly quota may go unused. \(reset)")
        }
        return String(localized: "\(remainingPercent)% of your weekly quota is still available. \(reset)")
    }
}
