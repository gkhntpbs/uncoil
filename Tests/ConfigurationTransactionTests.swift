import XCTest
@testable import Uncoil

@MainActor
final class ConfigurationTransactionServiceTests: XCTestCase {
    private var home: URL!
    private var adapter: ClaudeCodeAdapter!
    private var service: ConfigurationTransactionService!
    private var installation: AgentInstallation!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilConfigTx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"numStartups": 7}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))

        adapter = ClaudeCodeAdapter()
        adapter.homeDirectory = home
        adapter.binaryPathOverride = "/usr/bin/true"
        service = ConfigurationTransactionService(
            registry: AgentAdapterRegistry(adapters: [adapter])
        )
        installation = adapter.detectInstallations()[0]
    }

    private var changes: [ConfigurationChange] {
        [.addMCPServer(MCPServerDefinition(
            id: "x", name: "uncoil", transport: .stdio, command: "/Helpers/uncoil-mcp"
        ))]
    }

    private func configText() throws -> String {
        try String(contentsOf: home.appendingPathComponent(".claude.json"), encoding: .utf8)
    }

    func testPlanShowsTheDiffWithoutWriting() throws {
        let planned = try service.plan(changes, agent: .claudeCode, installation: installation)
        XCTAssertEqual(planned.transaction.status, .planned)
        XCTAssertTrue(planned.transaction.diff.contains("uncoil"))
        XCTAssertEqual(planned.transaction.baseHash, planned.configuration.hash)
        XCTAssertFalse(try configText().contains("uncoil"))
    }

    func testApplyWritesTheChangeAndKeepsABackup() throws {
        let planned = try service.plan(changes, agent: .claudeCode, installation: installation)
        let outcome = try service.apply(
            planned.transaction, changes: changes, installation: installation
        )
        XCTAssertTrue(outcome.didApply)
        XCTAssertFalse(outcome.needsReview)
        XCTAssertNotNil(outcome.transaction.backupPath)
        XCTAssertTrue(try configText().contains("uncoil"))
        XCTAssertTrue(try configText().contains("numStartups"))
    }

    func testExternalEditIsNotOverwrittenAndThePlanIsRecomputed() throws {
        let planned = try service.plan(changes, agent: .claudeCode, installation: installation)

        // The user edits the config after the plan was made.
        try Data(#"{"numStartups": 7, "theme": "dark"}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))

        let outcome = try service.apply(
            planned.transaction, changes: changes, installation: installation
        )
        XCTAssertFalse(outcome.didApply)
        XCTAssertEqual(outcome.transaction.status, .staleConfig)
        XCTAssertTrue(outcome.needsReview)

        // The user's edit survives, and the recomputed plan builds on it.
        XCTAssertTrue(try configText().contains("theme"))
        XCTAssertFalse(try configText().contains("uncoil"))
        XCTAssertNotEqual(outcome.replanned?.baseHash, planned.transaction.baseHash)

        let second = try service.apply(
            outcome.replanned!, changes: changes, installation: installation
        )
        XCTAssertTrue(second.didApply)
        XCTAssertTrue(try configText().contains("theme"), "still there after applying")
        XCTAssertTrue(try configText().contains("uncoil"))
    }

    func testRollbackRestoresTheSnapshotAndValidatesAfterwards() throws {
        let planned = try service.plan(changes, agent: .claudeCode, installation: installation)
        let applied = try service.apply(
            planned.transaction, changes: changes, installation: installation
        )
        let rolledBack = try service.rollback(applied.transaction, installation: installation)

        XCTAssertEqual(rolledBack.transaction.status, .rolledBack)
        XCTAssertFalse(try configText().contains("uncoil"))
        XCTAssertTrue(try configText().contains("numStartups"))
        XCTAssertTrue(
            rolledBack.issues.isEmpty,
            "the restored config validates clean"
        )
    }

    func testRollbackWithoutASnapshotKeepsTheCurrentFile() throws {
        let planned = try service.plan(changes, agent: .claudeCode, installation: installation)
        let outcome = try service.rollback(planned.transaction, installation: installation)
        XCTAssertNotEqual(outcome.transaction.status, .rolledBack)
        XCTAssertNotNil(outcome.transaction.failureReason)
        XCTAssertTrue(try configText().contains("numStartups"))
    }

    func testASecretValueNeverReachesTheAgentConfig() throws {
        let secretChange: [ConfigurationChange] = [
            .addMCPServer(MCPServerDefinition(
                id: "s", name: "supabase", transport: .stdio, command: "npx",
                environment: [
                    "SUPABASE_ACCESS_TOKEN": "sbp_secret",
                    "SUPABASE_NO_UPDATE_CHECK": "1",
                ]
            )),
        ]
        let planned = try service.plan(secretChange, agent: .claudeCode, installation: installation)
        XCTAssertFalse(planned.transaction.diff.contains("sbp_secret"), "not in the diff either")

        _ = try service.apply(planned.transaction, changes: secretChange, installation: installation)
        let written = try configText()
        XCTAssertFalse(written.contains("sbp_secret"))
        XCTAssertFalse(written.contains("SUPABASE_ACCESS_TOKEN"))
        XCTAssertTrue(written.contains("SUPABASE_NO_UPDATE_CHECK"), "plain values still land")
    }

    func testUnknownAgentIsRejectedRatherThanIgnored() {
        let empty = ConfigurationTransactionService(registry: AgentAdapterRegistry(adapters: []))
        XCTAssertThrowsError(
            try empty.plan(changes, agent: .claudeCode, installation: installation)
        )
    }

    func testAuditEventSummarisesTheDiffWithoutItsContent() throws {
        let planned = try service.plan(changes, agent: .claudeCode, installation: installation)
        let applied = try service.apply(
            planned.transaction, changes: changes, installation: installation
        )
        let event = ConfigurationTransactionService.auditEvent(
            for: applied, extensionID: "acme/uncoil"
        )
        XCTAssertEqual(event.kind, .configChanged)
        XCTAssertEqual(event.agent, .claudeCode)
        XCTAssertTrue(event.detail.contains("satır değişti"))
        XCTAssertFalse(event.detail.contains("uncoil-mcp"), "no config content in the audit line")
        XCTAssertTrue(event.isUndoable)
    }

    func testRollbackAuditEventIsDistinctFromAConfigChange() throws {
        let planned = try service.plan(changes, agent: .claudeCode, installation: installation)
        let applied = try service.apply(
            planned.transaction, changes: changes, installation: installation
        )
        let rolledBack = try service.rollback(applied.transaction, installation: installation)
        XCTAssertEqual(
            ConfigurationTransactionService.auditEvent(for: rolledBack, extensionID: nil).kind,
            .rolledBack
        )
    }

    func testStaleConfigIsAudited() throws {
        let planned = try service.plan(changes, agent: .claudeCode, installation: installation)
        try Data(#"{"numStartups": 8}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        let outcome = try service.apply(
            planned.transaction, changes: changes, installation: installation
        )
        let event = ConfigurationTransactionService.auditEvent(for: outcome, extensionID: nil)
        XCTAssertTrue(event.detail.contains("dışarıdan değişti"))
    }
}
