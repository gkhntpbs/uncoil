import Foundation

/// Whether an account is close enough to a limit to be worth saying so.
///
/// Pure, and separate from both the store and the views, because this is the
/// judgement the rest of the feature will be built on: the same evaluation that
/// raises a warning today is the one that will decide to hand work to another
/// agent later. It should be readable in one place and testable without either.
enum UsageAlert {

    enum State: String, Equatable, Comparable {
        /// Nothing to say. Includes an account whose usage cannot be read —
        /// silence is the only honest thing to do with a number we do not have.
        case none
        /// Under the threshold and still working.
        case approaching
        /// Out. Either the provider said so outright, or a window is empty.
        case reached

        var isAlerting: Bool { self != .none }

        static func < (lhs: State, rhs: State) -> Bool {
            let order: [State] = [.none, .approaching, .reached]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    /// The verdict, and the window it came from.
    struct Evaluation: Equatable {
        var state: State = .none
        /// The window that triggered it — whichever binds first.
        var window: UsageWindow?
        /// Whole percent remaining in that window, for a message.
        var remainingPercent: Int?
    }

    /// The default threshold, and the one the settings start at.
    static let defaultThreshold: Double = 15

    /// Evaluates one account.
    ///
    /// Three rules, in the order they are decided:
    ///
    /// 1. A snapshot with no numbers never alerts. There is nothing to compare,
    ///    and a warning drawn from an unknown is a guess wearing a warning's
    ///    clothes.
    /// 2. A provider that says outright it is out is out, whatever the
    ///    percentages say. Some accounts are refused before any window empties —
    ///    a spend cap, a team policy — and that is the case a threshold can
    ///    never catch, because it arrives with no warning at all.
    /// 3. Otherwise the window closest to running out decides, against the
    ///    user's threshold. Empty is `reached`, not `approaching`: there is
    ///    nothing left to approach.
    static func evaluate(
        _ snapshot: UsageSnapshot?,
        threshold: Double = defaultThreshold
    ) -> Evaluation {
        guard let snapshot, snapshot.unavailable == nil,
              let window = snapshot.mostConstrainedWindow else {
            // A provider can refuse before it reports anything; that refusal is
            // still worth surfacing even with no window behind it.
            if let snapshot, snapshot.limitReached {
                return Evaluation(state: .reached, window: nil, remainingPercent: nil)
            }
            return Evaluation()
        }

        let remaining = Int(window.remainingPercent.rounded(.down))
        if snapshot.limitReached || window.remainingPercent <= 0 {
            return Evaluation(state: .reached, window: window, remainingPercent: remaining)
        }
        if window.remainingPercent <= threshold {
            return Evaluation(state: .approaching, window: window, remainingPercent: remaining)
        }
        return Evaluation(state: .none, window: window, remainingPercent: remaining)
    }

    /// A stale figure still alerts.
    ///
    /// Usage only moves in one direction between resets, so a reading that was
    /// low twenty minutes ago is not less low now — it is at best exactly as
    /// low. Going quiet because the last refresh failed would take the warning
    /// away at the moment it is most likely to be right.
    ///
    /// The message says the figure is old, which is a different thing from
    /// pretending it is current.
    static func isTrustworthyEnoughToWarn(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.unavailable == nil && snapshot.hasQuota
    }
}
