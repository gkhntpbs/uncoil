import Foundation

/// What an update would actually change, gathered before it is applied.
///
/// The point is that "there is a newer commit" is not enough to decide with. A
/// user needs to see whether the new revision got riskier, asks for more, or
/// removed something they depend on.
struct UpdateReview: Equatable {
    /// Findings the scanner produced by comparing the two revisions.
    var securityDiff: [SecurityFinding] = []
    var addedPermissions: [String] = []
    var removedPermissions: [String] = []
    var addedTools: [String] = []
    var removedTools: [String] = []
    var changedFiles: [String] = []
    var commitCount = 0

    /// Whether the update looks like it could break what already works.
    ///
    /// Removals are the signal: a tool or permission that disappears is a promise
    /// withdrawn. New things can be ignored by whoever does not use them.
    var breakingChangeRisk: Risk {
        if !removedTools.isEmpty { return .likely }
        if !removedPermissions.isEmpty { return .possible }
        if securityDiff.contains(where: { $0.severity >= .high }) { return .possible }
        if changedFiles.contains(where: { $0.hasSuffix(".json") || $0.hasSuffix(".toml") }) {
            return .possible
        }
        return .unlikely
    }

    enum Risk: Equatable {
        case unlikely
        case possible
        case likely

        var label: String {
            switch self {
            case .unlikely: String(localized: "Low")
            case .possible: String(localized: "Possible")
            case .likely: String(localized: "High")
            }
        }
    }

    /// Whether this update should not be applied without a closer look.
    var needsReview: Bool {
        breakingChangeRisk != .unlikely
            || securityDiff.contains { $0.severity >= .needsReview }
            || !addedPermissions.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if commitCount > 0 { parts.append(String(localized: "\(commitCount) commit")) }
        if !changedFiles.isEmpty { parts.append(String(localized: "\(changedFiles.count) files")) }
        if !addedPermissions.isEmpty {
            parts.append(String(localized: "+\(addedPermissions.count) permission"))
        }
        if !removedTools.isEmpty { parts.append(String(localized: "-\(removedTools.count) tool")) }
        if !securityDiff.isEmpty { parts.append(String(localized: "\(securityDiff.count) security findings")) }
        return parts.isEmpty ? String(localized: "No changes") : parts.joined(separator: String(localized: " · "))
    }

    /// Builds the review from the two revisions on disk plus what the update
    /// check already found.
    @MainActor
    static func between(
        previous: URL?,
        next: URL,
        candidate: UpdateCandidate?,
        previousTools: [String] = [],
        nextTools: [String] = [],
        extensionID: String? = nil,
        now: Date = .now
    ) -> UpdateReview {
        var review = UpdateReview(
            changedFiles: candidate?.changedFiles ?? [],
            commitCount: candidate?.commitCount ?? 0
        )
        let nextClaims = ExtensionInstallPreviewBuilder.manifestClaims(at: next)
        let previousClaims = previous.map(ExtensionInstallPreviewBuilder.manifestClaims(at:))
            ?? (permissions: [], agents: [])
        review.addedPermissions = Set(nextClaims.permissions)
            .subtracting(previousClaims.permissions).sorted()
        review.removedPermissions = Set(previousClaims.permissions)
            .subtracting(nextClaims.permissions).sorted()
        review.addedTools = Set(nextTools).subtracting(previousTools).sorted()
        review.removedTools = Set(previousTools).subtracting(nextTools).sorted()

        let current = ExtensionSecurityScanner.scan(
            packageAt: next, extensionID: extensionID, now: now
        )
        if let previous {
            review.securityDiff = ExtensionSecurityScanner.diff(
                from: ExtensionSecurityScanner.scan(
                    packageAt: previous, extensionID: extensionID, now: now
                ),
                to: current,
                previousTools: previousTools,
                currentTools: nextTools,
                now: now
            )
        } else {
            review.securityDiff = current.findings.filter { $0.severity >= .needsReview }
        }
        return review
    }
}
