import XCTest
@testable import Uncoil

/// Runs the real routes against whatever is logged in on this machine.
///
/// Skipped unless `UNCOIL_USAGE_LIVE=1`, because it needs an account, a
/// network and an installed CLI — none of which a test suite may assume. It is
/// here because the parsers were written from a specification rather than from
/// captured traffic, and no fixture can tell you the endpoint is right. This is
/// the one check that can.
///
/// It prints rather than asserts a shape: the point is to find out what the
/// providers actually say. Values are redacted on the way out.
final class UsageLiveProbeTests: XCTestCase {
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["UNCOIL_USAGE_LIVE"] == "1"
    }

    private func report(_ label: String, _ outcome: UsageFetchOutcome) {
        var lines = ["\n=== \(label) ==="]
        for attempt in outcome.attempts {
            let state = attempt.skipped ? "skipped"
                : attempt.succeeded ? "OK"
                : (attempt.error?.summary ?? "failed")
            lines.append("  \(attempt.source.rawValue): \(state) (\(String(format: "%.1f", attempt.duration))s)")
        }
        if let snapshot = outcome.snapshot {
            lines.append("  source: \(snapshot.source.rawValue)")
            if let reason = snapshot.unavailable {
                lines.append("  unavailable: \(reason.rawValue)")
            }
            if let plan = snapshot.identity?.plan { lines.append("  plan: \(plan)") }
            for window in snapshot.allWindows {
                let reset = window.resetsAt.map { "resets \($0)" } ?? window.resetNote ?? "no reset"
                lines.append("  \(window.title): \(Int(window.remainingPercent))% left, \(reset)")
            }
        } else {
            lines.append("  no snapshot")
        }
        print(UsageCredentials.redacted(lines.joined(separator: "\n")))
    }

    /// Writes what `claude` actually drew, so the panel parser can be built
    /// against the real thing rather than against the documented shape.
    /// Redacted, and only where `UNCOIL_USAGE_SAMPLE_DIR` says.
    func testClaudePanelCapture() async throws {
        try XCTSkipUnless(isEnabled, "Set UNCOIL_USAGE_LIVE=1 to run the live probes")
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_USAGE_SAMPLE_DIR"],
              let executable = AgentAdapterSupport.locateBinary("claude") else {
            throw XCTSkip("Needs UNCOIL_USAGE_SAMPLE_DIR and an installed claude")
        }
        let probe = ClaudeUsageProbe(configuration: .init(
            executable: executable,
            workingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("uncoil-usage-probe", isDirectory: true),
            configDirectory: nil
        ))
        let raw = try probe.run()
        let root = URL(fileURLWithPath: directory)
        // The escapes matter as much as the text: a TUI moves the cursor where
        // a person would see a space, so what an escape is replaced *with*
        // decides whether "Current session" survives as two words.
        try UsageCredentials.redacted(raw.debugDescription).write(
            to: root.appendingPathComponent("claude-panel-raw.txt"),
            atomically: true, encoding: .utf8
        )
        let stripped = ClaudeUsagePanelParser.strippingANSI(raw)
        try UsageCredentials.redacted(stripped).write(
            to: root.appendingPathComponent("claude-panel.txt"),
            atomically: true, encoding: .utf8
        )
        print("captured \(raw.count) bytes, \(stripped.components(separatedBy: .newlines).count) lines")
    }

    func testClaudeCLIProbe() async throws {
        try XCTSkipUnless(isEnabled, "Set UNCOIL_USAGE_LIVE=1 to run the live probes")
        let strategy = ClaudeCLIUsageStrategy(
            executable: AgentAdapterSupport.locateBinary("claude"),
            probeDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("uncoil-usage-probe", isDirectory: true),
            configDirectory: nil,
            accountID: nil,
            clock: Date.init
        )
        let outcome = await UsageFetchPipeline.run(
            provider: .claude, accountID: nil, strategies: [strategy]
        )
        report("Claude — CLI panel", outcome)
    }

    /// Writes Codex's raw usage payload, with the keys kept and every value
    /// replaced by its type.
    ///
    /// The shape is the thing in doubt — whether a field this parser looks for
    /// exists, and under which spelling — and the shape is exactly the part
    /// that carries no account data.
    func testCodexPayloadShape() async throws {
        try XCTSkipUnless(isEnabled, "Set UNCOIL_USAGE_LIVE=1 to run the live probes")
        guard let directory = ProcessInfo.processInfo.environment["UNCOIL_USAGE_SAMPLE_DIR"] else {
            throw XCTSkip("Needs UNCOIL_USAGE_SAMPLE_DIR")
        }
        let recorder = RecordingHTTPClient()
        let provider = CodexUsageProvider(http: recorder)
        _ = await UsageFetchPipeline.run(
            provider: .codex, accountID: nil,
            strategies: [provider.strategies(for: .providerDefault).first!]
        )
        guard let body = recorder.lastBody,
              let json = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            throw XCTSkip("no Codex response to describe")
        }
        try Self.shape(of: json).write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("codex-usage-shape.txt"),
            atomically: true, encoding: .utf8
        )
    }

    /// The keys, nested, with types instead of values.
    private static func shape(of value: JSONValue, indent: String = "") -> String {
        switch value {
        case .object(let object):
            return object.keys.sorted().map { key in
                let child = object[key]!
                switch child {
                case .object, .array:
                    return "\(indent)\(key):\n\(shape(of: child, indent: indent + "  "))"
                default:
                    return "\(indent)\(key): \(shape(of: child))"
                }
            }.joined(separator: "\n")
        case .array(let array):
            guard let first = array.first else { return "\(indent)[] (empty)" }
            return "\(indent)[\(array.count)]:\n\(shape(of: first, indent: indent + "  "))"
        case .string: return "string"
        case .int, .double: return "number"
        case .bool: return "bool"
        case .null: return "null"
        }
    }

    func testCodexRoutes() async throws {
        try XCTSkipUnless(isEnabled, "Set UNCOIL_USAGE_LIVE=1 to run the live probes")
        let provider = CodexUsageProvider()
        let outcome = await UsageFetchPipeline.run(
            provider: .codex, accountID: nil,
            strategies: provider.strategies(for: .providerDefault)
        )
        report("Codex", outcome)
    }

    func testGeminiRoute() async throws {
        try XCTSkipUnless(isEnabled, "Set UNCOIL_USAGE_LIVE=1 to run the live probes")
        let provider = GeminiUsageProvider()
        let outcome = await UsageFetchPipeline.run(
            provider: .gemini, accountID: nil,
            strategies: provider.strategies(for: .providerDefault)
        )
        report("Gemini", outcome)
    }
}

/// Keeps the last response body so its shape can be described.
private final class RecordingHTTPClient: UsageHTTPClient, @unchecked Sendable {
    private let inner = UsageURLSessionClient()
    private let lock = NSLock()
    private var body: Data?

    var lastBody: Data? {
        lock.lock(); defer { lock.unlock() }
        return body
    }

    func send(_ request: UsageHTTPRequest) async throws -> UsageHTTPResponse {
        let response = try await inner.send(request)
        lock.lock(); body = response.body; lock.unlock()
        return response
    }
}
