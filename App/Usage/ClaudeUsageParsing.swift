import Foundation

/// Turns Claude's usage payload into a snapshot.
///
/// The shape has four named windows and an open list. The named ones are read
/// individually because they mean specific things — a five-hour session block
/// and a rolling week are not interchangeable — and the list is read whole,
/// because it is where a model that does not exist yet will appear.
enum ClaudeUsageParser {

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

        let primary = UsageJSON.object(root, ["five_hour", "fiveHour"]).flatMap {
            UsageJSON.window($0, id: "claude.five_hour", title: "Session limit", now: now)
        }
        let secondary = UsageJSON.object(root, ["seven_day", "sevenDay"]).flatMap {
            UsageJSON.window($0, id: "claude.seven_day", title: "Weekly limit", now: now)
        }

        var extras: [UsageWindow] = []
        // Model-scoped weeks are optional. An account on a plan that does not
        // separate them has neither, and treating their absence as a fault
        // would fail every such account.
        if let sonnet = UsageJSON.object(root, ["seven_day_sonnet", "sevenDaySonnet"]).flatMap({
            UsageJSON.window($0, id: "claude.seven_day_sonnet", title: "Weekly limit · Sonnet", modelID: "sonnet", now: now)
        }) {
            extras.append(sonnet)
        }
        if let opus = UsageJSON.object(root, ["seven_day_opus", "sevenDayOpus"]).flatMap({
            UsageJSON.window($0, id: "claude.seven_day_opus", title: "Weekly limit · Opus", modelID: "opus", now: now)
        }) {
            extras.append(opus)
        }
        extras.append(contentsOf: scopedLimits(root, now: now))

        let credits = extraUsage(root)

        // The five-hour window can be missing while the week is there. Losing
        // the whole provider over the absent half would hide a limit that is
        // present and, on a weekly plan, is the one that binds.
        if primary == nil, secondary == nil, extras.isEmpty {
            return .unavailable(
                provider: .claude,
                accountID: accountID,
                identity: identity,
                reason: .planReportsNoQuota,
                source: source,
                updatedAt: now
            )
        }

        return UsageSnapshot(
            provider: .claude,
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

    /// The open `limits` list, keeping only entries scoped to a week.
    ///
    /// Deduplicated against the named windows by model: the same Opus week
    /// arrives twice on some plans, once under its own key and once in the
    /// list, and showing it twice reads as two separate limits.
    static func scopedLimits(_ root: [String: JSONValue], now: Date) -> [UsageWindow] {
        guard let entries = UsageJSON.array(root, ["limits"]) else { return [] }
        var seen: Set<String> = ["sonnet", "opus"]
        var windows: [UsageWindow] = []

        for (index, entry) in entries.enumerated() {
            guard let object = entry.objectValue else { continue }
            let scoped = UsageJSON.object(object, ["weekly_scoped", "weeklyScoped"]) ?? object
            let model = UsageJSON.string(object, ["model", "model_id", "modelId"])
                ?? UsageJSON.string(scoped, ["model", "model_id", "modelId"])
            if let model, seen.contains(model.lowercased()) { continue }
            if let model { seen.insert(model.lowercased()) }

            let title = model.map { "Weekly limit · \($0)" }
                ?? UsageJSON.string(object, ["name", "label"])
                ?? "Weekly limit"
            guard let window = UsageJSON.window(
                scoped,
                id: "claude.limit.\(model ?? String(index))",
                title: title,
                modelID: model,
                now: now
            ) else { continue }
            windows.append(window)
        }
        return windows
    }

    /// `extra_usage` is spend, not quota.
    ///
    /// It is read into `credits` and nowhere near a window. Money spent past a
    /// limit says nothing about how much of the limit is left, and the moment
    /// the two are added together the resulting number cannot be interpreted at
    /// all.
    static func extraUsage(_ root: [String: JSONValue]) -> UsageCredits? {
        guard let object = UsageJSON.object(root, ["extra_usage", "extraUsage"]) else { return nil }
        let balance = UsageJSON.double(object, ["remaining", "balance", "limit", "amount", "spend", "used"])
        let currency = UsageJSON.string(object, ["currency", "unit"]) ?? "USD"
        let summary = UsageJSON.string(object, ["summary", "description", "status", "state"])
        guard balance != nil || summary != nil else { return nil }
        return UsageCredits(balance: balance, currency: currency, summary: summary)
    }

    static func identity(from json: JSONValue) -> UsageIdentity? {
        guard let root = json.objectValue else { return nil }
        let account = UsageJSON.object(root, ["account", "user", "profile"]) ?? root
        let organization = UsageJSON.object(root, ["organization", "org"])
        let email = UsageJSON.string(account, ["email", "email_address", "emailAddress"])
        let plan = UsageJSON.string(account, ["plan", "subscription_type", "subscriptionType", "tier"])
            ?? organization.flatMap { UsageJSON.string($0, ["plan", "billing_type", "billingType", "tier"]) }
        let organizationName = organization.flatMap { UsageJSON.string($0, ["name", "organization_name"]) }
            ?? UsageJSON.string(account, ["organization_name", "organizationName"])
        guard email != nil || plan != nil || organizationName != nil else { return nil }
        return UsageIdentity(email: email, plan: plan, organization: organizationName)
    }
}

// MARK: - The CLI panel

/// Reads the panel `claude` draws for `/usage`.
///
/// This is a text parser over a terminal rendering, and it is written knowing
/// that: the panel is a human interface with no compatibility promise, so the
/// parser looks for the two labels and a percentage near each of them rather
/// than for a layout. What it will not do is guess. A panel it cannot read
/// yields no window, and no window means "unavailable" — never a zero.
enum ClaudeUsagePanelParser {

    /// Section labels, in the order they appear.
    static let sessionLabels = ["current session"]
    static let weekLabels = ["current week"]

    struct Parsed: Equatable {
        var session: UsageWindow?
        var week: UsageWindow?
        var extras: [UsageWindow] = []
        var identity: UsageIdentity?
        /// Set when the CLI said something that means the probe cannot work —
        /// an expired login, a refusal — rather than merely printing nothing.
        var failure: UsageFetchError?
    }

    static func parse(_ raw: String) -> Parsed {
        let text = strippingANSI(raw)
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if let failure = failure(in: lines) {
            return Parsed(failure: failure)
        }

        var parsed = Parsed()
        parsed.session = window(
            in: lines, matching: sessionLabels,
            id: "claude.cli.session", title: "Session limit"
        )
        parsed.week = window(
            in: lines, matching: weekLabels,
            id: "claude.cli.week", title: "Weekly limit"
        )
        // A model line under the week ("Opus 47% used") becomes its own window,
        // since the account is limited by whichever binds first and that can be
        // the model rather than the total.
        parsed.extras = modelWindows(in: lines)
        return parsed
    }

    /// Explicit CLI errors, told apart from an empty panel.
    ///
    /// The distinction is the point: an expired login is worth stopping and
    /// reporting, whereas a panel that simply did not render in time is worth
    /// trying again later. Collapsing the two would either nag about a
    /// transient miss or stay quiet about a login that has to be redone.
    static func failure(in lines: [String]) -> UsageFetchError? {
        let joined = lines.joined(separator: " ").lowercased()
        if joined.contains("invalid api key") || joined.contains("authentication_error")
            || joined.contains("please run /login") || joined.contains("credentials have expired")
            || joined.contains("oauth token has expired") {
            return UsageFetchError(.credentialsExpired, detail: nil)
        }
        if joined.contains("usage is not available") || joined.contains("not available for your plan")
            || joined.contains("no usage limits") {
            return UsageFetchError(.planReportsNoQuota, detail: nil)
        }
        return nil
    }

    /// Finds a labelled section and the first percentage under it.
    ///
    /// Bounded to a few lines and stopped by the next label so a missing
    /// section cannot borrow the number belonging to the one after it — which
    /// is the failure that would show a weekly figure as a session figure and
    /// look entirely plausible.
    static func window(
        in lines: [String],
        matching labels: [String],
        id: String,
        title: String
    ) -> UsageWindow? {
        let allLabels = sessionLabels + weekLabels
        guard let start = lines.firstIndex(where: { line in
            let lowered = line.lowercased()
            return labels.contains { lowered.contains($0) }
        }) else { return nil }

        var used: Double?
        var note: String?
        let limit = min(start + 6, lines.count - 1)
        guard start <= limit else { return nil }

        for index in start...limit {
            let line = lines[index]
            let lowered = line.lowercased()
            if index > start, allLabels.contains(where: { lowered.contains($0) }) { break }
            if used == nil, let value = percentage(in: line) { used = value }
            if note == nil, let reset = resetNote(in: line) { note = reset }
            if used != nil, note != nil { break }
        }

        guard let used else { return nil }
        // No absolute instant: the panel prints a phrase, and turning "3:00pm"
        // into a date means inventing the day.
        return UsageWindow(id: id, title: title, usedPercent: used, resetNote: note)
    }

    /// Lines naming a model and a percentage, e.g. "Opus 47% used".
    static func modelWindows(in lines: [String]) -> [UsageWindow] {
        let models = ["opus", "sonnet", "haiku"]
        var windows: [UsageWindow] = []
        for line in lines {
            let lowered = line.lowercased()
            guard let model = models.first(where: { lowered.contains($0) }),
                  let used = percentage(in: line) else { continue }
            guard !windows.contains(where: { $0.modelID == model }) else { continue }
            windows.append(UsageWindow(
                id: "claude.cli.\(model)",
                title: "Weekly limit · \(model.capitalized)",
                usedPercent: used,
                resetNote: resetNote(in: line),
                modelID: model
            ))
        }
        return windows
    }

    /// A percentage on a line, normalised to "used".
    ///
    /// The word beside the number decides which half it is. A panel that says
    /// "77% left" and one that says "23% used" describe the same account, and
    /// reading either as the other inverts the number that a threshold will
    /// eventually be compared against.
    static func percentage(in line: String) -> Double? {
        guard let range = line.range(of: #"([0-9]+(\.[0-9]+)?)\s*%"#, options: .regularExpression),
              let value = Double(line[range].replacingOccurrences(of: "%", with: "")
                  .trimmingCharacters(in: .whitespaces)) else { return nil }
        let lowered = line.lowercased()
        if lowered.contains("left") || lowered.contains("remaining") || lowered.contains("available") {
            return 100 - value
        }
        return value
    }

    /// The provider's own words about the reset, kept verbatim.
    static func resetNote(in line: String) -> String? {
        guard let range = line.range(of: #"(?i)resets?\b"#, options: .regularExpression) else { return nil }
        let note = line[range.lowerBound...].trimmingCharacters(in: .whitespaces)
        return note.isEmpty ? nil : note
    }

    /// Removes escape sequences so the text can be read as text.
    ///
    /// Covers CSI and OSC, and the cursor-movement sequences a TUI uses to draw
    /// in place. What survives is the characters a person would see.
    static func strippingANSI(_ raw: String) -> String {
        var text = raw
        let patterns = [
            "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",   // CSI
            "\u{001B}\\][^\u{0007}\u{001B}]*(\u{0007}|\u{001B}\\\\)", // OSC
            "\u{001B}[@-Z\\\\-_]",              // two-character escapes
            "\r",
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }
}
