import Foundation

/// Turns Codex's rate-limit payloads into a snapshot.
///
/// Both Codex routes — the authenticated usage endpoint and the app-server's
/// `account/rateLimits/read` — describe the same thing in the same shape: a
/// primary (short) window, a secondary (long) window, and a list of additional
/// limits that are usually model-scoped. So one parser serves both, and the
/// only difference between the routes is how the bytes were obtained.
///
/// Pure by construction: every function here takes JSON and a clock and returns
/// a value. That is what makes the whole Codex path testable without a network,
/// a login, or a `codex` binary on the machine.
enum CodexUsageParser {

    /// Finds the rate-limit container wherever the route put it.
    ///
    /// The endpoint nests it under `rate_limit`; the RPC has been seen both
    /// nested and flat. Rather than two parsers that differ by one line, the
    /// container is located and the rest is common.
    static func rateLimitContainer(_ root: [String: JSONValue]) -> [String: JSONValue] {
        if let nested = UsageJSON.object(root, ["rate_limit", "rateLimit", "rate_limits", "rateLimits"]) {
            return nested
        }
        return root
    }

    static func snapshot(
        from json: JSONValue,
        accountID: UUID?,
        identity: UsageIdentity?,
        source: UsageSource,
        now: Date
    ) throws -> UsageSnapshot {
        guard let root = json.objectValue else {
            throw UsageFetchError(.malformedResponse, detail: "expected an object")
        }
        let container = rateLimitContainer(root)

        let primary = UsageJSON.object(container, ["primary_window", "primaryWindow", "primary"])
            .flatMap {
                UsageJSON.window(
                    $0,
                    id: "codex.primary",
                    title: UsageJSON.titleForWindow(
                        minutes: UsageJSON.windowMinutes($0), fallback: "Session limit"
                    ),
                    now: now
                )
            }

        let secondary = UsageJSON.object(container, ["secondary_window", "secondaryWindow", "secondary"])
            .flatMap {
                UsageJSON.window(
                    $0,
                    id: "codex.secondary",
                    title: UsageJSON.titleForWindow(
                        minutes: UsageJSON.windowMinutes($0), fallback: "Weekly limit"
                    ),
                    now: now
                )
            }

        let extras = additionalWindows(root: root, container: container, now: now)
        let credits = self.credits(root)

        // An authenticated account that reports no window at all is a real
        // state, and a different one from a failed request. Saying so here is
        // what stops the pipeline falling through to a second route to be told
        // the same thing.
        if primary == nil, secondary == nil, extras.isEmpty {
            return .unavailable(
                provider: .codex,
                accountID: accountID,
                identity: identity,
                reason: .planReportsNoQuota,
                source: source,
                updatedAt: now
            )
        }

        return UsageSnapshot(
            provider: .codex,
            accountID: accountID,
            identity: identity,
            primaryWindow: primary,
            secondaryWindow: secondary,
            extraWindows: extras,
            credits: credits,
            source: source,
            updatedAt: now
        )
    }

    /// Model-scoped and other extra limits.
    ///
    /// Kept as they arrive rather than folded into the two named windows: the
    /// list is where a provider puts a limit that did not exist when this code
    /// was written, and flattening it is how a new one becomes invisible.
    static func additionalWindows(
        root: [String: JSONValue],
        container: [String: JSONValue],
        now: Date
    ) -> [UsageWindow] {
        let entries = UsageJSON.array(root, ["additional_rate_limits", "additionalRateLimits"])
            ?? UsageJSON.array(container, ["additional_rate_limits", "additionalRateLimits"])
            ?? []

        return entries.enumerated().compactMap { index, entry in
            guard let object = entry.objectValue else { return nil }
            let model = UsageJSON.string(object, ["model", "model_id", "modelId", "model_slug"])
            let name = UsageJSON.string(object, ["name", "label", "title", "id"])
            let minutes = UsageJSON.windowMinutes(object)
            let title = name
                ?? model.map { "\($0) limit" }
                ?? UsageJSON.titleForWindow(minutes: minutes, fallback: "Additional limit")
            // The window itself may be nested one level down under the entry's
            // own key; both shapes appear.
            let source = UsageJSON.object(object, ["window", "rate_limit", "rateLimit"]) ?? object
            return UsageJSON.window(
                source,
                id: "codex.extra.\(model ?? name ?? String(index))",
                title: title,
                modelID: model,
                now: now
            )
        }
    }

    /// Credits, when the same response carries them.
    ///
    /// Read into their own field and never mixed with the windows: credits are
    /// money that buys usage past a limit, so adding them to a percentage would
    /// answer "how much is left" in two currencies at once.
    static func credits(_ root: [String: JSONValue]) -> UsageCredits? {
        guard let object = UsageJSON.object(root, ["credits", "credit_balance", "creditBalance", "balance"])
            ?? UsageJSON.object(root, ["usage_credits", "usageCredits"]) else {
            // A bare number is also a balance.
            if let amount = UsageJSON.double(root, ["credits", "credit_balance", "creditBalance"]) {
                return UsageCredits(balance: amount, currency: nil, summary: nil)
            }
            return nil
        }
        let balance = UsageJSON.double(object, ["balance", "remaining", "amount", "total"])
        let currency = UsageJSON.string(object, ["currency", "unit"])
        let summary = UsageJSON.string(object, ["summary", "description", "label"])
        guard balance != nil || summary != nil else { return nil }
        return UsageCredits(balance: balance, currency: currency, summary: summary)
    }

    /// Identity from `account/read`, or from whatever the usage endpoint
    /// happened to include beside the numbers.
    static func identity(from json: JSONValue) -> UsageIdentity? {
        guard let root = json.objectValue else { return nil }
        let account = UsageJSON.object(root, ["account", "user", "profile"]) ?? root
        let email = UsageJSON.string(account, ["email", "email_address", "emailAddress"])
        let plan = UsageJSON.string(account, ["plan", "plan_type", "planType", "subscription", "tier"])
            ?? UsageJSON.object(account, ["subscription"]).flatMap {
                UsageJSON.string($0, ["plan", "plan_type", "planType", "tier", "name"])
            }
        let organization = UsageJSON.string(account, ["organization", "org", "organization_name", "workspace"])
        guard email != nil || plan != nil || organization != nil else { return nil }
        return UsageIdentity(email: email, plan: plan, organization: organization)
    }
}
