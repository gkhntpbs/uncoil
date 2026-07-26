import Foundation

/// Drives agent-config edits through plan → apply → rollback.
///
/// Two rollbacks exist in this system and they are deliberately separate: an
/// extension rollback returns to a previous *revision* (`ExtensionUpdateEngine`),
/// while a config rollback restores the agent's *config file* — this service.
/// Rolling one back never implies the other.
@MainActor
struct ConfigurationTransactionService {
    var registry: AgentAdapterRegistry

    /// Result of applying a plan: the transaction plus what should be shown.
    struct Outcome: Equatable {
        var transaction: ConfigurationTransaction
        /// Set when the config changed under us — the recomputed plan to review.
        var replanned: ConfigurationTransaction?
        /// Validation run against the config as it now stands.
        var issues: [ConfigurationIssue]

        var didApply: Bool { transaction.status == .applied }
        var needsReview: Bool { replanned != nil }
    }

    // MARK: - Plan

    /// Reads the current config and builds a plan against it. Nothing is
    /// written, so the caller can show the diff first.
    func plan(
        _ changes: [ConfigurationChange],
        agent: ExtensionAgentID,
        installation: AgentInstallation
    ) throws -> (transaction: ConfigurationTransaction, configuration: AgentConfiguration) {
        guard let adapter = registry.adapter(for: agent) else {
            throw AgentAdapterError.unsupportedChange("No adapter for \(agent.displayName)")
        }
        let configuration = try adapter.readConfiguration(installation)
        return (try adapter.plan(changes, for: configuration), configuration)
    }

    // MARK: - Apply

    /// Applies a plan. When the file moved under us the write is refused and the
    /// plan is recomputed against the new config, so the user's own edit stays
    /// and the change is re-proposed on top of it instead of clobbering it.
    func apply(
        _ transaction: ConfigurationTransaction,
        changes: [ConfigurationChange],
        installation: AgentInstallation
    ) throws -> Outcome {
        guard let adapter = registry.adapter(for: transaction.agent) else {
            throw AgentAdapterError.unsupportedChange(
                "No adapter for \(transaction.agent.displayName)"
            )
        }
        let applied = try adapter.apply(transaction)
        if applied.status == .staleConfig {
            let current = try adapter.readConfiguration(installation)
            return Outcome(
                transaction: applied,
                replanned: try adapter.plan(changes, for: current),
                issues: adapter.validate(current)
            )
        }
        return Outcome(
            transaction: applied,
            replanned: nil,
            issues: adapter.validate(try adapter.readConfiguration(installation))
        )
    }

    // MARK: - Rollback

    /// Restores the snapshot the transaction captured and validates the agent's
    /// config afterwards, so a rollback that leaves a broken file is visible
    /// instead of silent.
    func rollback(
        _ transaction: ConfigurationTransaction,
        installation: AgentInstallation
    ) throws -> Outcome {
        guard let adapter = registry.adapter(for: transaction.agent) else {
            throw AgentAdapterError.unsupportedChange(
                "No adapter for \(transaction.agent.displayName)"
            )
        }
        let rolledBack = try adapter.rollback(transaction)
        guard rolledBack.status == .rolledBack else {
            // Restoring failed: the file on disk is untouched, so report the
            // reason rather than claiming a rollback happened.
            return Outcome(transaction: rolledBack, replanned: nil, issues: [])
        }
        return Outcome(
            transaction: rolledBack,
            replanned: nil,
            issues: adapter.validate(try adapter.readConfiguration(installation))
        )
    }

    // MARK: - Audit

    /// Audit entry for an applied or rolled-back config change. The diff is
    /// summarised by line counts — never the content, which carries whatever the
    /// user's config holds, including secrets.
    static func auditEvent(for outcome: Outcome, extensionID: String?) -> AuditEvent {
        let transaction = outcome.transaction
        let changed = transaction.diff
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("+") || $0.hasPrefix("-") }
            .count
        switch transaction.status {
        case .applied:
            return AuditEvent(
                kind: .configChanged,
                extensionID: extensionID,
                agent: transaction.agent,
                detail: "\(transaction.configPath): \(changed) lines changed",
                undoToken: transaction.backupPath
            )
        case .rolledBack:
            return AuditEvent(
                kind: .rolledBack,
                extensionID: extensionID,
                agent: transaction.agent,
                detail: "\(transaction.configPath) was restored from the backup"
            )
        case .staleConfig:
            return AuditEvent(
                kind: .configChanged,
                extensionID: extensionID,
                agent: transaction.agent,
                detail: "\(transaction.configPath) changed on disk; the plan was refreshed"
            )
        case .planned, .failed:
            return AuditEvent(
                kind: .configChanged,
                extensionID: extensionID,
                agent: transaction.agent,
                detail: transaction.failureReason
                    ?? "The plan for \(transaction.configPath) is ready"
            )
        }
    }
}
