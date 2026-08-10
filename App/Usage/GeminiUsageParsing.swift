import Foundation

/// Turns Gemini's Code Assist quota payload into a snapshot.
///
/// Gemini reports what is *left*, as a fraction, per model, and often several
/// times per model — one bucket per limit that applies to it. So there are two
/// normalisations here rather than one: fraction to percentage, and several
/// buckets to the one that binds.
enum GeminiUsageParser {

    /// Model families, used only to decide which window leads.
    ///
    /// Matched as prefixes so a model released next year lands in its family
    /// without a code change, and anything unrecognised keeps its own window
    /// rather than being dropped into one of these two.
    static let proFamily = ["gemini-3-pro", "gemini-2.5-pro", "gemini-1.5-pro", "gemini-pro"]
    static let flashFamily = ["gemini-3-flash", "gemini-2.5-flash", "gemini-1.5-flash", "gemini-flash"]

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

        let windows = modelWindows(root, now: now)
        guard !windows.isEmpty else {
            return .unavailable(
                provider: .gemini,
                accountID: accountID,
                identity: identity,
                reason: .planReportsNoQuota,
                source: source,
                updatedAt: now
            )
        }

        let primary = windows.first { belongs($0.modelID, to: proFamily) }
        let secondary = windows.first { belongs($0.modelID, to: flashFamily) }
        // Everything not already shown as one of the two leads, so a model
        // outside both families is still visible rather than silently dropped.
        let extras = windows.filter { $0.id != primary?.id && $0.id != secondary?.id }

        return UsageSnapshot(
            provider: .gemini,
            accountID: accountID,
            identity: identity,
            primaryWindow: primary,
            secondaryWindow: secondary,
            extraWindows: extras,
            source: source,
            updatedAt: now
        )
    }

    /// One window per model: the bucket with the least left.
    ///
    /// A model with a generous daily allowance and an exhausted per-minute one
    /// is exhausted, and reporting the generous number would be reporting the
    /// limit that is not biting. Sorted by how close each model is to running
    /// out, so the first thing a reader sees is the first thing to fail.
    static func modelWindows(_ root: [String: JSONValue], now: Date) -> [UsageWindow] {
        let buckets = UsageJSON.array(root, ["quotaBuckets", "quota_buckets", "buckets", "quotas"]) ?? []
        var lowest: [String: (fraction: Double, window: UsageWindow)] = [:]

        for entry in buckets {
            guard let object = entry.objectValue else { continue }
            let model = UsageJSON.string(object, ["modelId", "model_id", "model"]) ?? "gemini"
            guard let fraction = UsageJSON.double(
                object, ["remainingFraction", "remaining_fraction"]
            ) else { continue }

            let resetsAt = UsageJSON.date(
                object,
                absolute: ["resetTime", "reset_time", "resetsAt", "resets_at"],
                relativeSeconds: ["resetsInSeconds", "resets_in_seconds"],
                now: now
            )
            let window = UsageWindow.fromRemainingFraction(
                id: "gemini.\(model)",
                title: "\(model) quota",
                remainingFraction: fraction,
                resetsAt: resetsAt,
                modelID: model
            )
            if let existing = lowest[model], existing.fraction <= fraction { continue }
            lowest[model] = (fraction, window)
        }

        return lowest.values
            .map(\.window)
            .sorted { left, right in
                if left.remainingPercent != right.remainingPercent {
                    return left.remainingPercent < right.remainingPercent
                }
                return (left.modelID ?? "") < (right.modelID ?? "")
            }
    }

    static func belongs(_ modelID: String?, to family: [String]) -> Bool {
        guard let modelID = modelID?.lowercased() else { return false }
        return family.contains { modelID.hasPrefix($0) }
    }

    /// Project and tier, from `loadCodeAssist`.
    struct CodeAssistAccount: Equatable {
        var projectID: String?
        var tier: String?
        var identity: UsageIdentity?
        /// Set when the response itself says this account cannot use this route.
        var ineligible: Bool
    }

    static func account(from json: JSONValue) -> CodeAssistAccount {
        guard let root = json.objectValue else {
            return CodeAssistAccount(projectID: nil, tier: nil, identity: nil, ineligible: false)
        }
        let project = UsageJSON.string(root, ["cloudaicompanionProject", "cloudAicompanionProject", "project"])
        let tierObject = UsageJSON.object(root, ["currentTier", "current_tier", "tier"])
        let tier = tierObject.flatMap { UsageJSON.string($0, ["id", "name", "displayName"]) }
            ?? UsageJSON.string(root, ["currentTier", "tier"])

        // Only what the response says outright. Deciding eligibility from the
        // tier's name — treating "free" as ineligible, say — would be Uncoil
        // inventing Google's policy and then reporting it as fact.
        let ineligible = (tier?.lowercased()).map { name in
            name.contains("ineligible") || name.contains("unsupported")
        } ?? false

        let identity = tier.map { UsageIdentity(email: nil, plan: $0, organization: project) }
        return CodeAssistAccount(
            projectID: project, tier: tier, identity: identity, ineligible: ineligible
        )
    }

    /// Whether an error body says this class of account no longer has quota
    /// through this route.
    ///
    /// Google's withdrawal of the consumer tiers arrives as a refusal, not as
    /// an empty quota. Telling the two apart is what stops the app printing
    /// "0% remaining" for an account that in fact has a full allowance and is
    /// merely not readable from here.
    static func indicatesUnsupportedTier(_ body: Data) -> Bool {
        let text = String(decoding: body, as: UTF8.self).lowercased()
        let markers = [
            "unsupported client",
            "client is not supported",
            "not eligible",
            "ineligible",
            "no longer supported",
            "tier is not supported",
        ]
        return markers.contains { text.contains($0) }
    }
}
