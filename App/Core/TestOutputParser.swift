import Foundation

/// One test as its runner reported it.
struct TestCaseResult: Equatable, Identifiable, Codable {
    enum Outcome: String, Codable {
        case passed
        case failed
        case skipped
    }

    /// Suite / class / package, as the framework names it. Empty when the
    /// framework reports a flat list.
    var suite: String
    var name: String
    var outcome: Outcome
    /// Seconds, when the framework reports them.
    var duration: Double?
    /// The failure message, for a test that failed.
    var message: String?
    /// Files this test left behind — a screenshot, a recording. Empty unless
    /// the suite declares an `artifacts` directory in `.uncoil/tests.json`.
    var artifacts: [TestArtifact] = []

    var id: String { suite.isEmpty ? name : "\(suite).\(name)" }

    /// Records written before artifacts existed decode without the key.
    enum CodingKeys: String, CodingKey {
        case suite, name, outcome, duration, message, artifacts
    }

    init(
        suite: String,
        name: String,
        outcome: Outcome,
        duration: Double? = nil,
        message: String? = nil,
        artifacts: [TestArtifact] = []
    ) {
        self.suite = suite
        self.name = name
        self.outcome = outcome
        self.duration = duration
        self.message = message
        self.artifacts = artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        suite = try container.decode(String.self, forKey: .suite)
        name = try container.decode(String.self, forKey: .name)
        outcome = try container.decode(Outcome.self, forKey: .outcome)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        artifacts = try container.decodeIfPresent([TestArtifact].self, forKey: .artifacts) ?? []
    }
}

/// What a whole run came to.
struct TestRunSummary: Equatable, Codable {
    var passed = 0
    var failed = 0
    var skipped = 0
    /// True when the counts came from parsed output rather than from the exit
    /// code alone.
    ///
    /// Worth carrying: "0 failures" from a framework nobody parsed means only
    /// that the process exited 0, and showing that as a green per-test summary
    /// would be a claim the output never made.
    var isDetailed = false

    var total: Int { passed + failed + skipped }
    var didPass: Bool { failed == 0 }
}

/// Reads a test runner's output.
///
/// Only formats whose plain-text shape is documented and stable are parsed. A
/// framework Uncoil does not recognise still runs, and still reports pass or
/// fail from its exit code — but it reports no per-test breakdown, because
/// inventing one from output nobody parsed is worse than admitting there is
/// none.
enum TestOutputParser {
    /// Parses what the framework produced. `exitCode` is the fallback: it is
    /// what decides pass or fail when the output yielded nothing.
    static func parse(
        _ output: String, framework: TestFramework, exitCode: Int32?
    ) -> (cases: [TestCaseResult], summary: TestRunSummary) {
        var cases = cases(in: output, framework: framework)
        // Why the failures are read in a second pass: every runner prints them
        // somewhere other than the line that announced the outcome — before it,
        // after it, or in a summary at the end.
        let messages: [String: String] = switch framework {
        case .swift, .xcodebuild: xctestFailures(output)
        case .go: goFailures(output)
        case .cargo: cargoFailures(output)
        case .pytest: pytestFailures(output)
        case .jest, .unknown: [:]
        }
        if !messages.isEmpty {
            for index in cases.indices where cases[index].outcome == .failed {
                cases[index].message = messages[messageKey(cases[index].name)]
            }
        }
        guard !cases.isEmpty else {
            // Nothing recognised. The exit code is all there is, and saying so
            // is the point of `isDetailed`.
            var summary = TestRunSummary()
            if let exitCode, exitCode != 0 { summary.failed = 1 }
            return ([], summary)
        }
        var summary = TestRunSummary(isDetailed: true)
        for result in cases {
            switch result.outcome {
            case .passed: summary.passed += 1
            case .failed: summary.failed += 1
            case .skipped: summary.skipped += 1
            }
        }
        // A runner that crashed after reporting green tests did not pass, and
        // the counts alone would say it did.
        if summary.failed == 0, let exitCode, exitCode != 0 {
            summary.failed = 1
        }
        return (cases, summary)
    }

    /// The tests named in this output, without the second pass that reads
    /// failure messages. Split out because the live view parses every chunk as
    /// it arrives, and a message cannot be read from a chunk anyway.
    static func cases(in output: String, framework: TestFramework) -> [TestCaseResult] {
        switch framework {
        case .swift, .xcodebuild: parseXCTest(output)
        case .go: parseGoJSON(output)
        case .cargo: parseCargo(output)
        case .pytest: parsePytest(output)
        case .jest: parseJest(output)
        case .unknown: []
        }
    }

    // MARK: - Failure messages

    /// Failures are keyed by the test's own name rather than by
    /// `suite.name`, because the two passes do not always spell the suite the
    /// same way — `-[UncoilTests.HandoffTests testX]` in one line and
    /// `HandoffTests.testX` in another. The method name is the part every
    /// runner agrees on.
    static func messageKey(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]() ")).lowercased()
    }

    /// Keeps a message readable in a row: the first few lines, trimmed.
    private static func condense(_ lines: [String], limit: Int = 8) -> String? {
        let kept = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(limit)
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }

    /// `/path/File.swift:42: error: -[Suite testX] : XCTAssertEqual failed: …`
    /// swift-testing writes `✘ Test testX() recorded an issue … : message`, and
    /// both put the reason after the last `: ` on the line.
    static func xctestFailures(_ output: String) -> [String: String] {
        var found: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(" error: ") || trimmed.hasPrefix("✘") else { continue }
            let identifier: Substring
            if let open = trimmed.firstIndex(of: "[") {
                // `-[Suite method]` — the suite and the method are separated by
                // a space inside the brackets, and it is the method that the
                // other pass will have recorded.
                let rest = trimmed[trimmed.index(after: open)...]
                identifier = rest.prefix { $0 != "]" }
            } else if let start = trimmed.range(of: "Test ")?.upperBound {
                identifier = trimmed[start...].prefix { $0 != "(" && $0 != " " }
            } else {
                continue
            }
            let name = identifier
                .split(whereSeparator: { $0 == " " || $0 == "." })
                .last.map(String.init) ?? String(identifier)
            guard !name.isEmpty else { continue }
            let reason = trimmed.range(of: " : ").map { String(trimmed[$0.upperBound...]) }
                ?? trimmed.range(of: " error: ").map { String(trimmed[$0.upperBound...]) }
                ?? trimmed
            found[messageKey(name), default: []].append(reason)
        }
        return found.compactMapValues { condense($0) }
    }

    /// `go test -json` puts the failure in the test's own `Output` events, so
    /// the lines are gathered per test and kept only for the ones that failed.
    static func goFailures(_ output: String) -> [String: String] {
        var lines: [String: [String]] = [:]
        var failed = Set<String>()
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
                  let test = object["Test"]?.stringValue, !test.isEmpty,
                  let action = object["Action"]?.stringValue
            else { continue }
            let key = messageKey(test)
            if action == "fail" { failed.insert(key) }
            guard action == "output", let text = object["Output"]?.stringValue else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // The framing lines carry no information the row does not already
            // show, and they would be all a short message has room for.
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("=== RUN"), !trimmed.hasPrefix("=== PAUSE"),
                  !trimmed.hasPrefix("=== CONT"), !trimmed.hasPrefix("--- FAIL"),
                  !trimmed.hasPrefix("--- PASS"), trimmed != "PASS", trimmed != "FAIL"
            else { continue }
            lines[key, default: []].append(trimmed)
        }
        return lines.filter { failed.contains($0.key) }.compactMapValues { condense($0) }
    }

    /// cargo prints a `failures:` section of `---- module::name stdout ----`
    /// blocks, each running until the next block or a blank line.
    static func cargoFailures(_ output: String) -> [String: String] {
        var found: [String: [String]] = [:]
        var current: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("---- "), trimmed.hasSuffix(" ----") {
                let identifier = trimmed.dropFirst(5).dropLast(5)
                    .replacingOccurrences(of: " stdout", with: "")
                    .trimmingCharacters(in: .whitespaces)
                current = messageKey(identifier.components(separatedBy: "::").last ?? identifier)
                continue
            }
            guard let key = current else { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("failures:") { current = nil; continue }
            found[key, default: []].append(trimmed)
        }
        return found.compactMapValues { condense($0) }
    }

    /// pytest's short summary: `FAILED tests/test_x.py::test_name - AssertionError: …`.
    static func pytestFailures(_ output: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("FAILED ") || trimmed.hasPrefix("ERROR "),
                  let separator = trimmed.range(of: "::")
            else { continue }
            let rest = trimmed[separator.upperBound...]
            let name = rest.prefix { !$0.isWhitespace }
            guard !name.isEmpty else { continue }
            let reason = rest.range(of: " - ").map {
                String(rest[$0.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            guard let reason, !reason.isEmpty else { continue }
            found[messageKey(String(name))] = reason
        }
        return found
    }

    // MARK: - XCTest (swift test, xcodebuild)

    /// `Test Case '-[SuiteName testMethod]' passed (0.001 seconds).`
    /// swift test writes `Test Case 'SuiteName.testMethod' passed (…)` instead,
    /// so both bracket styles are read.
    static func parseXCTest(_ output: String) -> [TestCaseResult] {
        var results: [TestCaseResult] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Test Case ") else { continue }
            guard let open = trimmed.firstIndex(of: "'"),
                  let close = trimmed[trimmed.index(after: open)...].firstIndex(of: "'")
            else { continue }
            let identifier = String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: CharacterSet(charactersIn: "-[]"))
            let tail = trimmed[trimmed.index(after: close)...]
            let outcome: TestCaseResult.Outcome
            if tail.contains(" passed") { outcome = .passed }
            else if tail.contains(" failed") { outcome = .failed }
            else if tail.contains(" skipped") { outcome = .skipped }
            else { continue }  // "started" lines, which pair with these

            // `-[Suite method]` uses a space, `Suite.method` a dot.
            let parts = identifier.contains(" ")
                ? identifier.split(separator: " ", maxSplits: 1).map(String.init)
                : identifier.split(separator: ".", maxSplits: 1).map(String.init)
            results.append(TestCaseResult(
                suite: parts.count == 2 ? parts[0] : "",
                name: parts.last ?? identifier,
                outcome: outcome,
                duration: seconds(in: String(tail))
            ))
        }
        return results
    }

    /// `(0.123 seconds)` at the end of an XCTest line.
    private static func seconds(in text: String) -> Double? {
        guard let open = text.lastIndex(of: "("),
              let close = text.lastIndex(of: ")"), open < close else { return nil }
        let inner = text[text.index(after: open)..<close]
        guard inner.hasSuffix("seconds") else { return nil }
        return Double(inner.dropLast("seconds".count).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - go test -json

    /// `go test -json` emits one JSON object per event. Only the terminal
    /// actions matter, and only those carrying a `Test` — the same actions
    /// without one are the package's own summary and would double every count.
    static func parseGoJSON(_ output: String) -> [TestCaseResult] {
        var results: [TestCaseResult] = []
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let object = value.objectValue,
                  let test = object["Test"]?.stringValue, !test.isEmpty,
                  let action = object["Action"]?.stringValue
            else { continue }
            let outcome: TestCaseResult.Outcome
            switch action {
            case "pass": outcome = .passed
            case "fail": outcome = .failed
            case "skip": outcome = .skipped
            default: continue
            }
            results.append(TestCaseResult(
                suite: object["Package"]?.stringValue ?? "",
                name: test,
                outcome: outcome,
                duration: object["Elapsed"]?.doubleValue
            ))
        }
        return results
    }

    // MARK: - cargo test

    /// `test module::name ... ok` / `... FAILED` / `... ignored`.
    static func parseCargo(_ output: String) -> [TestCaseResult] {
        var results: [TestCaseResult] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("test "), let range = trimmed.range(of: " ... ")
            else { continue }
            let identifier = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !identifier.isEmpty else { continue }
            let verdict = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let outcome: TestCaseResult.Outcome
            if verdict.hasPrefix("ok") { outcome = .passed }
            else if verdict.hasPrefix("FAILED") { outcome = .failed }
            else if verdict.hasPrefix("ignored") { outcome = .skipped }
            else { continue }
            let parts = identifier.components(separatedBy: "::")
            results.append(TestCaseResult(
                suite: parts.count > 1 ? parts.dropLast().joined(separator: "::") : "",
                name: parts.last ?? identifier,
                outcome: outcome
            ))
        }
        return results
    }

    // MARK: - pytest -v

    /// `tests/test_x.py::test_name PASSED  [ 50%]`. The default output is a row
    /// of dots with no names in it, which is why detection adds `-v`.
    static func parsePytest(_ output: String) -> [TestCaseResult] {
        var results: [TestCaseResult] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.range(of: "::") else { continue }
            let file = String(trimmed[trimmed.startIndex..<separator.lowerBound])
            guard file.hasSuffix(".py") else { continue }
            let rest = trimmed[separator.upperBound...]
            let fields = rest.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = fields.first, fields.count >= 2 else { continue }
            let outcome: TestCaseResult.Outcome
            switch fields[1].uppercased() {
            case "PASSED", "XPASS": outcome = .passed
            case "FAILED", "ERROR": outcome = .failed
            case "SKIPPED", "XFAIL": outcome = .skipped
            default: continue
            }
            results.append(TestCaseResult(
                suite: file, name: String(name), outcome: outcome
            ))
        }
        return results
    }

    // MARK: - Jest / Vitest

    /// Both print `✓ name (2 ms)` / `✗ name` / `× name` / `↓ name` per test,
    /// under a heading naming the file. Jest also uses `✕`.
    static func parseJest(_ output: String) -> [TestCaseResult] {
        var results: [TestCaseResult] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let marker = trimmed.first else { continue }
            let outcome: TestCaseResult.Outcome
            switch marker {
            case "✓", "√": outcome = .passed
            case "✕", "✗", "×": outcome = .failed
            case "↓", "○", "-": outcome = .skipped
            default: continue
            }
            var name = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // Strip the trailing "(12 ms)" duration, when present.
            var duration: Double?
            if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
                let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
                if let value = milliseconds(inner) {
                    duration = value
                    name = String(name[name.startIndex..<open])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            guard !name.isEmpty else { continue }
            results.append(TestCaseResult(
                suite: "", name: name, outcome: outcome, duration: duration
            ))
        }
        return results
    }

    /// "12 ms" / "1.2 s" → seconds. Anything else is not a duration, and the
    /// parenthesis it came from is part of the test's name.
    private static func milliseconds(_ text: Substring) -> Double? {
        let fields = text.split(separator: " ")
        guard fields.count == 2, let value = Double(fields[0]) else { return nil }
        switch fields[1] {
        case "ms": return value / 1000
        case "s": return value
        default: return nil
        }
    }
}
