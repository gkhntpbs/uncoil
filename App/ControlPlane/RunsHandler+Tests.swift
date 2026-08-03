import Foundation

/// The test-suite half of `uncoil_run`.
///
/// Deliberately actions on the existing tool rather than a ninth one: the MCP
/// surface is eight tools by design, and a suite is the same kind of thing a run
/// is — a project-owned command with a working directory. It reuses the `runs.*`
/// grants for the same reason: an agent allowed to start a dev server is
/// allowed to run the tests, and `runs.write` is already what lets it edit a
/// repo-owned command file.
extension CapabilityRouter {
    func handleTestAction(
        _ request: ControlRequest, project: Project, grants: Set<String>
    ) async -> ControlEnvelope? {
        switch request.action {
        case "test_list":
            guard grants.contains("runs.read") else { return testDenied(request, "runs.read") }
            return listSuites(request, project: project)
        case "test_detect":
            guard grants.contains("runs.write") else { return testDenied(request, "runs.write") }
            return detectSuites(request, project: project)
        case "test_update":
            guard grants.contains("runs.write") else { return testDenied(request, "runs.write") }
            return updateSuite(request, project: project)
        case "test_results":
            guard grants.contains("runs.read") else { return testDenied(request, "runs.read") }
            return testResults(request, project: project)
        case "test_run":
            guard grants.contains("runs.control") else {
                return testDenied(request, "runs.control")
            }
            return await runSuite(request, project: project)
        default:
            // Not a test action; the caller carries on with the run actions.
            return nil
        }
    }

    private func testDenied(_ request: ControlRequest, _ grant: String) -> ControlEnvelope {
        .failure(request, code: .capabilityDisabled, message: "\(grant) is not granted")
    }

    // MARK: - Reading

    private func listSuites(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        let contents = TestConfigFile.load(projectRoot: project.rootURL)
        return .success(request, data: .object([
            "suites": .array(contents.suites.map { $0.asJSON() }),
            "total": .int(contents.suites.count),
        ]), project_id: project.id.uuidString, warnings: contents.problems)
    }

    private func testResults(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        let suites = TestConfigFile.load(projectRoot: project.rootURL).suites
        let requested = request.args["id"]?.stringValue
        let wanted = requested.map { id in suites.filter { $0.id == id } } ?? suites
        guard !wanted.isEmpty else {
            return .failure(
                request, code: .invalidAction,
                message: requested.map { "no suite '\($0)'; use test_list or test_detect" }
                    ?? "no test suites; use test_detect"
            )
        }
        let directory = TestRegistry.shared.resultsDirectory(projectID: project.id)
        let entries = wanted.map { suite -> JSONValue in
            guard let record = TestRegistry.loadRecord(
                suiteID: suite.id, directory: directory
            ) else {
                return .object([
                    "id": .string(suite.id),
                    "name": .string(suite.name),
                    "status": .string("never_run"),
                ])
            }
            return .object([
                "id": .string(suite.id),
                "name": .string(suite.name),
                "status": .string(record.summary.didPass ? "passed" : "failed"),
                "passed": .int(record.summary.passed),
                "failed": .int(record.summary.failed),
                "skipped": .int(record.summary.skipped),
                // Says whether the counts were read from the output or are just
                // the exit code. An agent acting on "0 failures" deserves to
                // know which of the two it is looking at.
                "detailed": .bool(record.summary.isDetailed),
                "framework": .string(suite.framework.rawValue),
                "finished_at": .string(record.finishedAt.map(Self.iso) ?? ""),
                "failures": .array(record.failedCases.prefix(50).map { result in
                    .object([
                        "suite": .string(result.suite),
                        "name": .string(result.name),
                    ])
                }),
            ])
        }
        return .success(request, data: .object([
            "results": .array(entries),
        ]), project_id: project.id.uuidString)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Writing

    private func detectSuites(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        let replace = request.args["replace"]?.boolValue ?? false
        let existing = TestConfigFile.load(projectRoot: project.rootURL).suites
        let suggestions = TestDetection.detect(
            fileSystem: DiskRunDetectionFileSystem(root: project.rootURL)
        )
        let merged = TestConfigFile.merge(
            existing: existing, suggestions: suggestions, replacingDetected: replace
        )
        do {
            try TestConfigFile.save(merged, projectRoot: project.rootURL)
        } catch {
            return .failure(
                request, code: .ioError,
                message: "could not write tests.json: \(error.localizedDescription)"
            )
        }
        let added = Set(merged.map(\.id)).subtracting(existing.map(\.id))
        return .success(request, data: .object([
            "suites": .array(merged.map { $0.asJSON() }),
            "added": .array(added.sorted().map(JSONValue.string)),
            "total": .int(merged.count),
        ]), project_id: project.id.uuidString,
           warnings: merged.isEmpty
               ? ["no test suite could be detected; write .uncoil/tests.json by hand"] : [])
    }

    /// Creates or replaces one suite — how an agent adds tests it has written.
    private func updateSuite(_ request: ControlRequest, project: Project) -> ControlEnvelope {
        var raw = request.args["suite"]
        // Some MCP clients deliver nested arguments as a JSON string; accept
        // that rather than making agents fight encoding.
        if case .string(let text)? = raw,
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
           parsed.objectValue != nil {
            raw = parsed
        }
        guard let value = raw,
              let data = try? JSONEncoder().encode(value),
              var suite = try? JSONDecoder().decode(TestSuiteConfiguration.self, from: data)
        else {
            return .failure(
                request, code: .invalidArgument,
                message: "suite must be an object with 'id' and 'command'"
            )
        }
        // Stamped, not taken on trust: whatever the agent claims, this entry
        // was written by an agent, and detection must not later replace it as
        // though it had proposed it.
        suite.source = .agent

        var suites = TestConfigFile.load(projectRoot: project.rootURL).suites
        if let index = suites.firstIndex(where: { $0.id == suite.id }) {
            suites[index] = suite
        } else {
            suites.append(suite)
        }
        if suite.isDefault {
            suites = suites.map { entry in
                var entry = entry
                entry.isDefault = entry.id == suite.id
                return entry
            }
        }
        do {
            try TestConfigFile.save(suites, projectRoot: project.rootURL)
        } catch {
            return .failure(
                request, code: .ioError,
                message: "could not write tests.json: \(error.localizedDescription)"
            )
        }
        return .success(request, data: .object([
            "suite": suite.asJSON(),
        ]), project_id: project.id.uuidString)
    }

    // MARK: - Running

    private func runSuite(_ request: ControlRequest, project: Project) async -> ControlEnvelope {
        let suites = TestConfigFile.load(projectRoot: project.rootURL).suites
        let suite: TestSuiteConfiguration?
        if let id = request.args["id"]?.stringValue {
            suite = suites.first { $0.id == id }
        } else {
            suite = TestConfigFile.defaultSuite(suites)
        }
        guard let suite else {
            return .failure(
                request, code: .invalidAction,
                message: suites.isEmpty
                    ? "no test suites; use test_detect first"
                    : "no suite matched; pass 'id', or mark one 'default'"
            )
        }
        guard let record = await TestRegistry.shared.run(project: project, suite: suite) else {
            return .failure(
                request, code: .ioError,
                message: "could not start '\(suite.id)'; it may already be running"
            )
        }
        return .success(request, data: .object([
            "id": .string(suite.id),
            "status": .string(record.summary.didPass ? "passed" : "failed"),
            "passed": .int(record.summary.passed),
            "failed": .int(record.summary.failed),
            "skipped": .int(record.summary.skipped),
            "detailed": .bool(record.summary.isDetailed),
            "exit_code": record.exitCode.map { JSONValue.int(Int($0)) } ?? .null,
            "failures": .array(record.failedCases.prefix(50).map { result in
                .object(["suite": .string(result.suite), "name": .string(result.name)])
            }),
            // The tail is the only thing that explains a failure an
            // unrecognised framework reported, so it travels with the result.
            "log_tail": .string(String(record.logTail.suffix(4000))),
        ]), project_id: project.id.uuidString,
           warnings: record.summary.isDetailed ? [] : [
               "the output format of this suite is not recognised, so only the overall "
                   + "pass/fail is reported; individual test results are not available",
           ])
    }
}
