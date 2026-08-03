import Foundation

/// Which shortcuts the quick-launch strip offers, and in what order.
///
/// The strip used to be `AgentProvider.sessionKinds` — every provider Uncoil
/// knows, in declaration order. That is wrong twice over: it offers agents the
/// user has not installed, and it has no room for the ordering someone actually
/// works in. Both are choices, so they are stored.
struct LauncherPrefs: Codable, Equatable {
    /// Ordered, left to right. Empty means "not configured yet", which resolves
    /// to the default rather than to an empty strip.
    var order: [AgentProvider] = []

    static let `default` = LauncherPrefs()

    /// One rule, and it is a hard one: a strip with nothing in it removes the
    /// only way to start a session from this screen. Whatever the user does,
    /// something has to stay.
    static let minimumItems = 1

    /// What the strip shows, given what is actually installed.
    ///
    /// An unconfigured strip offers the terminal plus every agent the machine
    /// has, because an agent that is not installed is a button that can only
    /// fail. A configured one is honoured as written, minus anything that has
    /// since disappeared — but never emptied: an entry whose CLI is missing is
    /// still the user's stated choice, and dropping the last one would leave
    /// nothing to click.
    static func resolved(
        _ prefs: LauncherPrefs, installed: Set<AgentProvider>
    ) -> [AgentProvider] {
        guard !prefs.order.isEmpty else {
            let detected = AgentProvider.sessionKinds.filter {
                !$0.isAgent || installed.contains($0)
            }
            return detected.isEmpty ? [.terminal] : detected
        }
        var seen = Set<AgentProvider>()
        let unique = prefs.order.filter { seen.insert($0).inserted }
        let present = unique.filter { !$0.isAgent || installed.contains($0) }
        if present.count >= minimumItems { return present }
        // Everything the user chose is gone. Their first choice is kept anyway
        // rather than substituting one they never asked for.
        return Array(unique.prefix(minimumItems))
    }

    /// Whether an entry may be removed. False for the last one.
    static func canRemove(from order: [AgentProvider]) -> Bool {
        order.count > minimumItems
    }

    /// Removes an entry, refusing when it is the last.
    static func removing(_ provider: AgentProvider, from order: [AgentProvider]) -> [AgentProvider] {
        guard canRemove(from: order) else { return order }
        return order.filter { $0 != provider }
    }

    /// Appends an entry it does not already hold.
    static func adding(_ provider: AgentProvider, to order: [AgentProvider]) -> [AgentProvider] {
        order.contains(provider) ? order : order + [provider]
    }

    /// Drag-reorder: moves `provider` to `index` in the current display order.
    static func moving(
        _ provider: AgentProvider, to index: Int, in order: [AgentProvider]
    ) -> [AgentProvider] {
        guard let from = order.firstIndex(of: provider) else { return order }
        var result = order
        result.remove(at: from)
        // The removal shifts everything after it left by one, so a drop past
        // the original position lands one slot too far without this.
        let target = min(max(0, from < index ? index - 1 : index), result.count)
        result.insert(provider, at: target)
        return result
    }
}
