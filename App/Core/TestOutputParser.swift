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

    var id: String { suite.isEmpty ? name : "\(suite).\(name)" }
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
        let cases: [TestCaseResult] = switch framework {
        case .swift, .xcodebuild: parseXCTest(output)
        case .go: parseGoJSON(output)
        case .cargo: parseCargo(output)
        case .pytest: parsePytest(output)
        case .jest: parseJest(output)
        case .unknown: []
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
