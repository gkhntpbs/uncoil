import XCTest
@testable import Uncoil

final class SSHConfigParserTests: XCTestCase {
    private var sshDirectory: URL!

    override func setUpWithError() throws {
        sshDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-ssh-\(UUID().uuidString)/.ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sshDirectory.deletingLastPathComponent())
    }

    private func write(_ text: String, _ name: String) throws {
        let url = sshDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private var parser: SSHConfigParser { SSHConfigParser(sshDirectory: sshDirectory) }

    func testConcreteHostsAreFoundAndPatternsSkipped() {
        let entries = parser.parse(text: """
        # personal
        Host matrix
            HostName 192.168.1.20
            User gokhan
            Port 2222
            IdentityFile ~/.ssh/id_ed25519

        Host *.internal !bastion office-*
            User ops

        Host *
            ServerAliveInterval 30
        """)
        XCTAssertEqual(entries.map(\.alias), ["matrix"])
        let matrix = entries[0]
        XCTAssertEqual(matrix.hostName, "192.168.1.20")
        XCTAssertEqual(matrix.user, "gokhan")
        XCTAssertEqual(matrix.port, 2222)
        XCTAssertEqual(matrix.identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(matrix.line, 2)
    }

    func testOneHostLineCanNameSeveralHostsAndFirstValueWins() {
        let entries = parser.parse(text: """
        Host staging-api production-api
          User deploy
        Host production-api
          User root
          HostName prod.example.com
        Host=office-server
          HostName = 10.0.0.9
        """)
        XCTAssertEqual(entries.map(\.alias), ["staging-api", "production-api", "office-server"])
        XCTAssertEqual(entries[1].user, "deploy")
        XCTAssertEqual(entries[1].hostName, "prod.example.com")
        XCTAssertEqual(entries[2].hostName, "10.0.0.9")
        XCTAssertNil(entries[0].hostName)
    }

    func testMatchBlocksBelongToNoHost() {
        let entries = parser.parse(text: """
        Host a
          User one
        Match host a
          User two
          HostName nowhere
        """)
        XCTAssertEqual(entries.first?.user, "one")
        XCTAssertNil(entries.first?.hostName)
    }

    func testIncludesAreFollowedRelativeToSSHDirectoryWithGlobs() throws {
        try write("""
        Include config.d/*
        Include ~/.ssh/extra
        Host main
          HostName main.example.com
        """, "config")
        try write("Host from-glob-b\n  HostName b\n", "config.d/b.conf")
        try write("Host from-glob-a\n  HostName a\n", "config.d/a.conf")
        try write("Host from-tilde\n", "extra")
        let entries = parser.parse()
        XCTAssertEqual(entries.map(\.alias), ["from-glob-a", "from-glob-b", "from-tilde", "main"])
        XCTAssertTrue(entries[0].sourcePath.hasSuffix("config.d/a.conf"), entries[0].sourcePath)
    }

    func testUncoilsOwnFileIsNotReadBackAsSystemHosts() throws {
        try write("Include uncoil_config\nHost mine\n", "config")
        try write("Host written-by-uncoil\n", "uncoil_config")
        let excluded = sshDirectory.appendingPathComponent("uncoil_config").standardizedFileURL.path
        let entries = SSHConfigParser(sshDirectory: sshDirectory, excludedPaths: [excluded]).parse()
        XCTAssertEqual(entries.map(\.alias), ["mine"])
    }

    func testAnIncludeCycleEnds() throws {
        try write("Include config\nHost loop\n", "config")
        XCTAssertEqual(parser.parse().map(\.alias), ["loop"])
    }
}

final class SSHConfigWriterTests: XCTestCase {
    private var home: URL!
    private var writer: SSHConfigWriter!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("uncoil-home-\(UUID().uuidString)")
        writer = SSHConfigWriter(sshDirectory: home.appendingPathComponent(".ssh"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testUncoilConfigHasAHeaderAndOnlyUncoilHosts() throws {
        XCTAssertTrue(writer.writeUncoilConfig([
            SSHHost(alias: "staging-api", hostName: "10.0.0.5", user: "deploy", port: 22,
                    identityFile: "~/.ssh/My Key", note: "Staging", origin: .uncoil),
            SSHHost(alias: "matrix", hostName: "should-not-appear", origin: .system),
        ]))
        let text = try String(contentsOf: writer.uncoilConfigURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Managed by Uncoil"), text)
        XCTAssertTrue(text.contains("Host staging-api\n    HostName 10.0.0.5\n    User deploy\n    Port 22\n"), text)
        XCTAssertTrue(text.contains("IdentityFile \"~/.ssh/My Key\""), text)
        XCTAssertFalse(text.contains("matrix"), text)
        let permissions = try FileManager.default.attributesOfItem(atPath: writer.uncoilConfigURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        // What Uncoil writes, OpenSSH-style, it can read back.
        let parsed = SSHConfigParser(sshDirectory: writer.sshDirectory).parse(configURL: writer.uncoilConfigURL)
        XCTAssertEqual(parsed.first?.identityFile, "~/.ssh/My Key")
    }

    func testIncludeGoesOnTopOnceWithABackup() throws {
        let original = "Host matrix\n  HostName 192.168.1.20\n"
        try FileManager.default.createDirectory(at: writer.sshDirectory, withIntermediateDirectories: true)
        try original.write(to: writer.configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: writer.configURL.path)
        XCTAssertEqual(writer.includeStatus(), .missing)

        try writer.installInclude()
        let once = try String(contentsOf: writer.configURL, encoding: .utf8)
        XCTAssertTrue(once.hasPrefix("\(SSHConfigWriter.includeMarker)\nInclude uncoil_config\n"), once)
        XCTAssertTrue(once.hasSuffix(original), once)
        XCTAssertEqual(try String(contentsOf: writer.backupURL, encoding: .utf8), original)
        XCTAssertEqual(writer.includeStatus(), .installed)
        let permissions = try FileManager.default.attributesOfItem(atPath: writer.configURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o644)

        try writer.installInclude()
        XCTAssertEqual(try String(contentsOf: writer.configURL, encoding: .utf8), once)
        // The backup is still the user's file, not Uncoil's edit of it.
        XCTAssertEqual(try String(contentsOf: writer.backupURL, encoding: .utf8), original)
    }

    func testIncludeIntoAMissingConfigCreatesIt() throws {
        try writer.installInclude()
        XCTAssertEqual(writer.includeStatus(), .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.backupURL.path))
    }

    func testAnIncludeAfterAHostBlockIsMisplaced() {
        XCTAssertEqual(SSHConfigWriter.includeStatus(in: "Host a\nInclude uncoil_config\n"), .misplaced)
        XCTAssertEqual(SSHConfigWriter.includeStatus(in: "  include ~/.ssh/uncoil_config\nHost a\n"), .installed)
    }

    @MainActor
    func testAnUncoilAliasThatTheSystemConfigDefinesIsRefused() throws {
        try FileManager.default.createDirectory(at: writer.sshDirectory, withIntermediateDirectories: true)
        try "Host matrix\n".write(to: writer.configURL, atomically: true, encoding: .utf8)
        let store = ProjectStore(directory: home.appendingPathComponent("data"))
        let service = SSHHostService(sshDirectory: writer.sshDirectory)
        service.rescan(store: store)

        let clash = SSHHost(alias: "matrix", hostName: "elsewhere", origin: .uncoil)
        guard case .systemConflict = service.validate(clash, replacing: nil, store: store) else {
            return XCTFail("expected a conflict")
        }
        XCTAssertThrowsError(try service.save(clash, replacing: nil, store: store))
        XCTAssertNil(store.sshHost(alias: "matrix"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.uncoilConfigURL.path))

        XCTAssertEqual(service.validate(SSHHost(alias: "bad alias", origin: .uncoil), replacing: nil, store: store), .invalidAlias)
        try service.save(SSHHost(alias: "fresh", hostName: "10.0.0.1", origin: .uncoil), replacing: nil, store: store)
        XCTAssertTrue(try String(contentsOf: writer.uncoilConfigURL, encoding: .utf8).contains("Host fresh"))
        XCTAssertEqual(service.validate(SSHHost(alias: "fresh", origin: .uncoil), replacing: nil, store: store), .duplicate)
    }
}

@MainActor
final class SSHHostStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("uncoil-sshstore-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testProjectDecodesWithAndWithoutHostAliases() throws {
        let old = #"{"id":"6F9A4B1E-0000-4000-8000-000000000001","name":"Old","rootPath":"/tmp/old","createdAt":0}"#
        let decoded = try JSONDecoder().decode(Project.self, from: Data(old.utf8))
        XCTAssertNil(decoded.sshHostAliases)

        var project = Project(name: "New", rootPath: "/tmp/new")
        project.sshHostAliases = ["matrix"]
        let roundTrip = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(roundTrip.sshHostAliases, ["matrix"])
    }

    func testRenamingAndDeletingAHostFollowsTheAssociations() throws {
        let store = ProjectStore(directory: directory)
        let a = try XCTUnwrap(store.addProject(at: URL(fileURLWithPath: "/tmp/ssh-a")))
        let b = try XCTUnwrap(store.addProject(at: URL(fileURLWithPath: "/tmp/ssh-b")))
        store.saveSSHHost(SSHHost(alias: "matrix", origin: .uncoil))
        store.setSSHHost("matrix", associated: true, with: a.id)
        store.setSSHHost("matrix", associated: true, with: b.id)
        XCTAssertEqual(store.projects(usingSSHHost: "matrix").count, 2)

        store.saveSSHHost(SSHHost(alias: "neo", origin: .uncoil), replacing: "matrix")
        XCTAssertNil(store.sshHost(alias: "matrix"))
        XCTAssertEqual(store.projects(usingSSHHost: "neo").count, 2)
        XCTAssertEqual(store.projects(usingSSHHost: "matrix").count, 0)

        // Persisted, and read back by the next launch.
        let reloaded = ProjectStore(directory: directory)
        XCTAssertEqual(reloaded.sshHosts.map(\.alias), ["neo"])
        XCTAssertEqual(reloaded.projects.first { $0.id == a.id }?.sshHostAliases, ["neo"])

        reloaded.removeSSHHost(alias: "neo")
        XCTAssertTrue(reloaded.sshHosts.isEmpty)
        XCTAssertTrue(reloaded.projects.allSatisfy { $0.sshHostAliases == nil })
    }

    func testRefreshingSystemHostsKeepsTheNote() {
        let store = ProjectStore(directory: directory)
        store.saveSSHHost(SSHHost(alias: "matrix", hostName: "old", note: "Dev box", origin: .system))
        store.refreshSystemHosts(from: [
            SSHConfigEntry(alias: "matrix", hostName: "new", user: "me", sourcePath: "/x", line: 1),
        ])
        XCTAssertEqual(store.sshHost(alias: "matrix")?.hostName, "new")
        XCTAssertEqual(store.sshHost(alias: "matrix")?.note, "Dev box")
    }
}

final class ProjectContextBuilderTests: XCTestCase {
    private let hosts = [
        SSHHost(alias: "matrix", note: "Personal development machine", origin: .system),
        SSHHost(alias: "office-server", hostName: "10.1.0.2", origin: .system),
        SSHHost(alias: "staging-api", hostName: "10.0.0.5", user: "deploy", port: 22,
                note: "Staging environment", origin: .uncoil),
        SSHHost(alias: "production-api", origin: .uncoil),
    ]

    private func project(_ aliases: [String]?) -> Project {
        var project = Project(name: "p", rootPath: "/tmp/p")
        project.sshHostAliases = aliases
        return project
    }

    func testEachProjectGetsOnlyItsOwnHosts() throws {
        let company = try XCTUnwrap(ProjectContextBuilder.build(
            for: project(["office-server", "staging-api", "production-api"]), hosts: hosts))
        XCTAssertTrue(company.hasPrefix("## Remote hosts for this project (from Uncoil)\n"), company)
        XCTAssertTrue(company.contains("- staging-api — Staging environment (deploy@10.0.0.5:22)\n"), company)
        XCTAssertTrue(company.contains("- office-server (10.1.0.2)\n"), company)
        XCTAssertTrue(company.contains("- production-api\n"), company)
        XCTAssertFalse(company.contains("matrix"), company)
        XCTAssertTrue(company.contains("Connect with `ssh <alias>`"), company)
        XCTAssertTrue(company.contains(#"uncoil_projects {"action":"context"}"#), company)

        let personal = try XCTUnwrap(ProjectContextBuilder.build(for: project(["matrix"]), hosts: hosts))
        XCTAssertTrue(personal.contains("- matrix — Personal development machine"), personal)
        XCTAssertFalse(personal.contains("staging-api"), personal)
    }

    func testNothingToSayIsNil() {
        XCTAssertNil(ProjectContextBuilder.build(for: project(nil), hosts: hosts))
        XCTAssertNil(ProjectContextBuilder.build(for: project([]), hosts: hosts))
        // An alias whose host is gone says nothing rather than naming a ghost.
        XCTAssertNil(ProjectContextBuilder.build(for: project(["deleted"]), hosts: hosts))
    }
}

final class ProjectContextLaunchTests: XCTestCase {
    private let context = "## Remote hosts for this project (from Uncoil)\n- staging-api — it's \"staging\"\nConnect with `ssh <alias>`."

    private func command(_ provider: AgentProvider, resume: AgentResumeDecision = .fresh(nil), context: String?) -> String? {
        let record = SessionRecord(projectID: UUID(), provider: provider, accountID: nil, title: "t")
        return TerminalRegistry.launchCommand(
            for: record, binaryPath: "/usr/local/bin/\(provider.rawValue)", resume: resume,
            extraArguments: nil, projectContext: context)
    }

    /// Runs the command's arguments through a real shell and returns argv.
    private func argv(_ command: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "set -- \(command); for a in \"$@\"; do printf '%s\\0' \"$a\"; done"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }

    func testClaudeGetsTheBlockAsAnAppendedSystemPrompt() throws {
        let line = try XCTUnwrap(command(.claude, context: context))
        let args = try argv(line)
        let index = try XCTUnwrap(args.firstIndex(of: "--append-system-prompt"))
        XCTAssertEqual(args[index + 1], context)

        let resumed = try argv(try XCTUnwrap(command(.claude, resume: .resume("abc"), context: context)))
        XCTAssertTrue(resumed.contains("--resume"))
        XCTAssertTrue(resumed.contains(context))
    }

    func testCodexGetsTheBlockAsDeveloperInstructions() throws {
        let args = try argv(try XCTUnwrap(command(.codex, resume: .resume("thread-1"), context: context)))
        XCTAssertEqual(Array(args.prefix(3)), ["/usr/local/bin/codex", "resume", "thread-1"])
        let override = try XCTUnwrap(args.first { $0.hasPrefix("developer_instructions=") })
        XCTAssertEqual(
            override,
            ###"developer_instructions="## Remote hosts for this project (from Uncoil)\n- staging-api — it's \"staging\"\nConnect with `ssh <alias>`.""###)
    }

    func testNoContextAddsNothing() throws {
        XCTAssertFalse(try XCTUnwrap(command(.claude, context: nil)).contains("--append-system-prompt"))
        XCTAssertFalse(try XCTUnwrap(command(.codex, context: nil)).contains("developer_instructions"))
    }

    func testTheStructuredClaudeLaunchCarriesItToo() {
        let record = SessionRecord(projectID: UUID(), provider: .claude, accountID: nil, title: "t")
        let arguments = ClaudeStreamProtocol.arguments(
            record: record, resume: .fresh(nil), newSessionID: "s", mcpConfigPath: nil,
            scope: .unrestricted, modeArguments: [], projectContext: context)
        let index = arguments.firstIndex(of: "--append-system-prompt")
        XCTAssertEqual(index.map { arguments[$0 + 1] }, context)
    }

    func testAnAttachedUncoilServerAddsTheToolsSection() throws {
        let record = SessionRecord(projectID: UUID(), provider: .claude, accountID: nil, title: "t")
        let attached = ClaudeStreamProtocol.arguments(
            record: record, resume: .fresh(nil), newSessionID: "s", mcpConfigPath: "/tmp/mcp.json",
            scope: .unrestricted, modeArguments: [], projectContext: context)
        let prompt = try XCTUnwrap(attached.firstIndex(of: "--append-system-prompt").map { attached[$0 + 1] })
        XCTAssertTrue(prompt.hasPrefix("## \(ProjectContextBuilder.uncoilToolsSection.title)\n"), prompt)
        XCTAssertTrue(prompt.hasSuffix(context), prompt)

        let bare = ClaudeStreamProtocol.arguments(
            record: record, resume: .fresh(nil), newSessionID: "s", mcpConfigPath: "/tmp/mcp.json",
            scope: .unrestricted, modeArguments: [])
        XCTAssertTrue(bare.contains(ProjectContextBuilder.withUncoilTools(nil)))

        let codex = TerminalRegistry.launchCommand(
            for: SessionRecord(projectID: UUID(), provider: .codex, accountID: nil, title: "t"),
            binaryPath: "/usr/local/bin/codex", resume: .fresh(nil), mcpBinaryPath: "/x/uncoil-mcp",
            extraArguments: nil, projectContext: nil)
        let codexArgs = try argv(try XCTUnwrap(codex))
        XCTAssertTrue(codexArgs.contains { $0.hasPrefix("developer_instructions=") && $0.contains("uncoil_browser") })
    }

    func testNoServerNoToolsSection() throws {
        let line = try XCTUnwrap(command(.claude, context: context))
        XCTAssertFalse(line.contains("Uncoil tools"))
    }

    func testAnSSHTerminalRunsSSHInsteadOfAShell() throws {
        var record = SessionRecord(projectID: UUID(), provider: .terminal, accountID: nil, title: "ssh matrix")
        XCTAssertNil(TerminalRegistry.launchCommand(for: record, resume: .fresh(nil), extraArguments: nil))
        record.shellCommand = ["ssh", "matrix"]
        let line = try XCTUnwrap(TerminalRegistry.launchCommand(for: record, resume: .fresh(nil), extraArguments: nil))
        XCTAssertEqual(try argv(line), ["ssh", "matrix"])
    }
}
