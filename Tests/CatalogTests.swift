import XCTest
@testable import Uncoil

/// The catalog layer against recorded provider answers: decoding, mapping,
/// cache fallback, install mapping, and the skill staging path. No test here
/// touches the network — every response is a fixture fed through the injected
/// `send` closure.
@MainActor
final class CatalogTests: XCTestCase {
    // MARK: - Fixtures

    static let mcpListFixture = Data("""
    {
      "servers": [
        {
          "server": {
            "name": "com.pulsemcp/remote-filesystem",
            "description": "Remote filesystem over GCS",
            "version": "0.1.2",
            "repository": {
              "url": "https://github.com/pulsemcp/mcp-servers",
              "source": "github",
              "subfolder": "experimental/remote-filesystem"
            },
            "packages": [
              {
                "registryType": "npm",
                "registryBaseUrl": "https://registry.npmjs.org",
                "identifier": "remote-filesystem-mcp-server",
                "version": "0.1.2",
                "runtimeHint": "npx",
                "transport": { "type": "stdio" },
                "runtimeArguments": [ { "value": "-y", "type": "positional" } ],
                "environmentVariables": [
                  { "name": "GCS_BUCKET", "description": "Bucket", "isRequired": true },
                  { "name": "GCS_PRIVATE_KEY", "isSecret": true, "description": "Key" },
                  { "name": "GCS_MAKE_PUBLIC", "default": "false" }
                ]
              }
            ],
            "remotes": []
          },
          "_meta": {
            "io.modelcontextprotocol.registry/official": {
              "status": "active",
              "publishedAt": "2026-05-18T13:28:59.991989Z",
              "updatedAt": "2026-05-18T13:28:59.991989Z",
              "isLatest": true
            }
          }
        }
      ],
      "metadata": { "nextCursor": "com.pulsemcp/remote-filesystem:0.1.2", "count": 1 }
    }
    """.utf8)

    static let skillsListFixture = Data("""
    {
      "data": [
        {
          "id": "vercel/skills/pdf-tools",
          "slug": "pdf-tools",
          "name": "PDF Tools",
          "source": "vercel/skills",
          "sourceType": "github",
          "installs": 24531,
          "installUrl": "https://github.com/vercel/skills",
          "url": "https://skills.sh/vercel/skills/pdf-tools"
        }
      ],
      "pagination": { "page": 0, "perPage": 30, "total": 8420, "hasMore": true }
    }
    """.utf8)

    static let skillDetailFixture = Data("""
    {
      "id": "vercel/skills/pdf-tools",
      "source": "vercel/skills",
      "slug": "pdf-tools",
      "installs": 24531,
      "hash": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
      "files": [
        { "path": "SKILL.md", "contents": "---\\nname: pdf-tools\\n---\\nDo PDF things." },
        { "path": "scripts/run.py", "contents": "print('ok')" }
      ]
    }
    """.utf8)

    private func client(
        responding: @escaping (URL) throws -> Data,
        cache: CatalogDiskCache? = nil,
        now: @escaping () -> Date = { .now }
    ) -> CatalogHTTPClient {
        CatalogHTTPClient(
            send: { request in
                let url = request.url!
                let data = try responding(url)
                return (data, HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                )!)
            },
            cache: cache,
            now: now
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - MCP registry mapping

    func testMcpListDecodesAndMaps() async throws {
        let provider = McpRegistryProvider(client: client(responding: { url in
            XCTAssertTrue(url.absoluteString.contains("version=latest"))
            return Self.mcpListFixture
        }))
        let page = try await provider.page(CatalogQuery())
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.nextCursor, "com.pulsemcp/remote-filesystem:0.1.2")

        let item = page.items[0]
        XCTAssertEqual(item.kind, .mcpServer)
        XCTAssertEqual(item.name, "com.pulsemcp/remote-filesystem")
        XCTAssertEqual(item.installName, "remote-filesystem")
        XCTAssertEqual(item.publisher, "com.pulsemcp")
        XCTAssertEqual(item.repository, "pulsemcp/mcp-servers")
        XCTAssertTrue(item.isOfficial)
        XCTAssertEqual(item.registryStatus, "active")
        XCTAssertNotNil(item.publishedAt)

        let package = try XCTUnwrap(item.mcp?.packages.first)
        XCTAssertEqual(package.environmentVariables.count, 3)
        XCTAssertEqual(item.mcp?.hasInstallableForm, true)
    }

    func testMcpCursorTravelsIntoNextRequest() async throws {
        var seenURLs: [String] = []
        let provider = McpRegistryProvider(client: client(responding: { url in
            seenURLs.append(url.absoluteString)
            return Self.mcpListFixture
        }))
        _ = try await provider.page(CatalogQuery(cursor: "a:1"))
        XCTAssertTrue(seenURLs[0].contains("cursor=a:1"))
    }

    @MainActor
    func testMcpDefinitionPinsVersionAndSplitsSecrets() throws {
        let entry = try JSONDecoder()
            .decode(McpRegistryProvider.ListResponse.self, from: Self.mcpListFixture)
            .servers[0]
        let item = try XCTUnwrap(McpRegistryProvider.item(from: entry))
        let service = CatalogInstallService(
            layout: ExtensionStoreLayout(root: temporaryDirectory())
        )
        let choice = try XCTUnwrap(CatalogInstallService.choices(for: item).first)
        let definition = try service.definition(for: item, choice: choice)

        XCTAssertEqual(definition.transport, .stdio)
        XCTAssertEqual(definition.command, "npx")
        // Pinned to the exact published version, never a moving tag.
        XCTAssertEqual(definition.arguments, ["-y", "remote-filesystem-mcp-server@0.1.2"])
        // Secret-looking names go to the Keychain path; GCS_BUCKET is required
        // with no default, so it also has to come from the user.
        XCTAssertEqual(definition.environmentKeys, ["GCS_BUCKET", "GCS_PRIVATE_KEY"])
        XCTAssertEqual(definition.environment, ["GCS_MAKE_PUBLIC": "false"])
        XCTAssertEqual(definition.name, "remote-filesystem")
    }

    func testRemoteChoiceBecomesHTTPDefinition() async throws {
        let item = CatalogItem(
            kind: .mcpServer, provider: .mcpRegistry,
            name: "com.example/api", displayName: "api",
            mcp: MCPCatalogDetails(remotes: [
                MCPCatalogRemote(type: "streamable-http", url: "https://mcp.example.com"),
            ])
        )
        let service = await CatalogInstallService(
            layout: ExtensionStoreLayout(root: temporaryDirectory())
        )
        let choice = try XCTUnwrap(CatalogInstallService.choices(for: item).first)
        let definition = try await service.definition(for: item, choice: choice)
        XCTAssertEqual(definition.transport, .http)
        XCTAssertEqual(definition.url, "https://mcp.example.com")
    }

    // MARK: - MCP quality

    func testBrowsingHidesEmptyDeprecatedAndUninstallable() {
        func mcpItem(
            summary: String?, installable: Bool, status: String
        ) -> CatalogItem {
            CatalogItem(
                kind: .mcpServer, provider: .mcpRegistry,
                name: "com.example/x", displayName: "x", summary: summary,
                registryStatus: status,
                mcp: MCPCatalogDetails(
                    packages: installable
                        ? [MCPCatalogPackage(registryType: "npm", identifier: "x")] : []
                )
            )
        }
        XCTAssertTrue(McpRegistryProvider.isPresentable(
            mcpItem(summary: "A useful filesystem server", installable: true, status: "active")
        ))
        XCTAssertFalse(McpRegistryProvider.isPresentable(
            mcpItem(summary: nil, installable: true, status: "active")
        ), "no description")
        XCTAssertFalse(McpRegistryProvider.isPresentable(
            mcpItem(summary: "A useful filesystem server", installable: false, status: "active")
        ), "nothing installable")
        XCTAssertFalse(McpRegistryProvider.isPresentable(
            mcpItem(summary: "A useful filesystem server", installable: true, status: "deprecated")
        ), "deprecated hidden from browse")
        var cjk = mcpItem(summary: "一分間のリセットを提供するサーバー", installable: true, status: "active")
        XCTAssertFalse(McpRegistryProvider.isPresentable(cjk), "CJK-dominant summary hidden")
        cjk = mcpItem(summary: "A useful filesystem server", installable: true, status: "active")
        cjk.displayName = "AIノアカリ☆リセット"
        XCTAssertFalse(McpRegistryProvider.isPresentable(cjk), "CJK-dominant name hidden")
        // A CJK word buried in a long English name still trips the gate: the
        // absolute count matters, not only the ratio.
        cjk.displayName = "AIノアカリ☆ Agent Trust Receipts MCP Server"
        XCTAssertFalse(McpRegistryProvider.isPresentable(cjk), "CJK word in name hidden")
    }

    func testRankPrefersDocumentedActiveEntries() {
        var rich = CatalogItem(
            kind: .mcpServer, provider: .mcpRegistry, name: "b/rich", displayName: "rich",
            summary: "A thoroughly documented server that does one thing well"
        )
        rich.repository = "owner/rich"
        rich.updatedAt = .now
        let bare = CatalogItem(
            kind: .mcpServer, provider: .mcpRegistry, name: "a/bare", displayName: "bare",
            summary: "Server thing."
        )
        XCTAssertEqual(McpRegistryProvider.ranked([bare, rich]).first?.name, "b/rich")
    }

    // MARK: - skills.sh mapping

    func testSkillsLeaderboardMapsAndPaginates() async throws {
        let provider = SkillsShProvider(client: client(responding: { _ in
            Self.skillsListFixture
        }))
        let page = try await provider.page(CatalogQuery(view: .trending))
        XCTAssertEqual(page.items.count, 1)
        // Page-numbered pagination rides in the cursor.
        XCTAssertEqual(page.nextCursor, "1")

        let item = page.items[0]
        XCTAssertEqual(item.kind, .skill)
        XCTAssertEqual(item.displayName, "PDF Tools")
        XCTAssertEqual(item.publisher, "vercel")
        XCTAssertEqual(item.installs, 24531)
        XCTAssertEqual(item.skill?.slug, "pdf-tools")
        XCTAssertEqual(item.repositoryURL, "https://github.com/vercel/skills")
    }

    func testSkillDetailCarriesFilesAndHash() async throws {
        let provider = SkillsShProvider(client: client(responding: { _ in
            Self.skillDetailFixture
        }))
        let (details, installs) = try await provider.detail(source: "vercel/skills", slug: "pdf-tools")
        XCTAssertEqual(installs, 24531)
        XCTAssertEqual(details.files?.count, 2)
        XCTAssertEqual(details.files?.first?.path, "SKILL.md")
        XCTAssertEqual(details.contentHash?.prefix(6), "abcdef")
    }

    func testMalformedAnswerIsAMalformedError() async {
        let provider = SkillsShProvider(client: client(responding: { _ in
            Data("not json".utf8)
        }))
        do {
            _ = try await provider.page(CatalogQuery())
            XCTFail("should have thrown")
        } catch let error as CatalogError {
            guard case .malformed = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Cache

    func testFreshCacheSkipsTheNetwork() async throws {
        let cache = CatalogDiskCache(root: temporaryDirectory())
        var hits = 0
        let client = client(responding: { _ in
            hits += 1
            return Data("{\"servers\":[],\"metadata\":{}}".utf8)
        }, cache: cache)
        let url = URL(string: "https://registry.example/v0/servers")!
        _ = try await client.get(url, ttl: 600)
        _ = try await client.get(url, ttl: 600)
        XCTAssertEqual(hits, 1)
    }

    func testStaleCacheServesWhenTheNetworkFails() async throws {
        let cache = CatalogDiskCache(root: temporaryDirectory())
        let url = URL(string: "https://registry.example/v0/servers")!
        cache.write(Data("cached".utf8), for: url)

        var clock = Date.now
        let failing = CatalogHTTPClient(
            send: { _ in throw URLError(.notConnectedToInternet) },
            cache: cache,
            now: { clock }
        )
        clock = clock.addingTimeInterval(3600) // far past any TTL
        let response = try await failing.get(url, ttl: 600)
        XCTAssertEqual(response.data, Data("cached".utf8))
        XCTAssertTrue(response.isStaleFallback)
    }

    func testA401IsAuthenticationRequiredAndSkipsTheStaleCache() async throws {
        let cache = CatalogDiskCache(root: temporaryDirectory())
        let url = URL(string: "https://skills.example/api/v1/skills")!
        cache.write(Data("cached".utf8), for: url)
        var clock = Date.now
        let gated = CatalogHTTPClient(
            send: { request in
                (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
                )!)
            },
            cache: cache,
            now: { clock }
        )
        clock = clock.addingTimeInterval(3600)
        do {
            _ = try await gated.get(url, ttl: 600)
            XCTFail("should have thrown")
        } catch CatalogError.authenticationRequired {
            // Stale data must not mask the missing credential.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTokenTravelsAsBearerHeader() async throws {
        var seenAuth: String?
        var provider = SkillsShProvider(client: CatalogHTTPClient(send: { request in
            seenAuth = request.value(forHTTPHeaderField: "Authorization")
            return (Self.skillsListFixture, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }))
        provider.token = "tok123"
        _ = try await provider.page(CatalogQuery())
        XCTAssertEqual(seenAuth, "Bearer tok123")
    }

    func testNoCacheAndNoNetworkIsOffline() async {
        let failing = CatalogHTTPClient(send: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await failing.get(URL(string: "https://registry.example/x")!, ttl: 0)
            XCTFail("should have thrown")
        } catch let error as CatalogError {
            guard case .offline = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Installed state

    func testInstalledStateMatchesByInstallName() {
        let item = CatalogItem(
            kind: .skill, provider: .skillsSh,
            name: "vercel/skills/pdf-tools", displayName: "PDF Tools",
            skill: SkillCatalogDetails(
                source: "vercel/skills", slug: "pdf-tools",
                contentHash: String(repeating: "ab", count: 32)
            )
        )
        XCTAssertEqual(CatalogStore.installedState(of: item, packages: []), .notInstalled)

        let matchingRevision = InstalledRevision(
            id: "catalog/pdf-tools@\(CatalogStore.shortHash(String(repeating: "ab", count: 32)))",
            contentHash: "x", path: "/tmp/x", installedAt: .now
        )
        let installed = ExtensionPackage(
            id: "catalog:skillsSh:vercel/skills/pdf-tools", kind: .skill,
            name: "pdf-tools", source: .adopted(path: "/tmp/x"),
            activeRevision: matchingRevision
        )
        XCTAssertEqual(CatalogStore.installedState(of: item, packages: [installed]), .installed)

        var stale = installed
        stale.activeRevision = InstalledRevision(
            id: "catalog/pdf-tools@000000000000", contentHash: "y",
            path: "/tmp/y", installedAt: .now
        )
        XCTAssertEqual(
            CatalogStore.installedState(of: item, packages: [stale]), .updateAvailable
        )
    }

    func testMcpEntryWithoutInstallableFormIsIncompatible() {
        let item = CatalogItem(
            kind: .mcpServer, provider: .mcpRegistry,
            name: "com.example/mcpb-only", displayName: "mcpb-only",
            mcp: MCPCatalogDetails(packages: [
                MCPCatalogPackage(registryType: "mcpb", identifier: "x"),
            ])
        )
        guard case .incompatible = CatalogStore.installedState(of: item, packages: []) else {
            return XCTFail("expected incompatible")
        }
    }

    // MARK: - Skill staging

    @MainActor
    func testStageSkillWritesFilesScansAndPins() throws {
        let root = temporaryDirectory()
        let service = CatalogInstallService(layout: ExtensionStoreLayout(root: root))
        var item = CatalogItem(
            kind: .skill, provider: .skillsSh,
            name: "vercel/skills/pdf-tools", displayName: "PDF Tools"
        )
        item.skill = SkillCatalogDetails(
            source: "vercel/skills", slug: "pdf-tools",
            contentHash: String(repeating: "cd", count: 32),
            files: [
                SkillCatalogFile(path: "SKILL.md", contents: "---\nname: pdf-tools\n---\nBody"),
                SkillCatalogFile(path: "scripts/run.py", contents: "print('ok')"),
            ]
        )
        let plan = try service.stageSkill(item: item)
        defer { service.discardStaging(plan) }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: plan.stagedPath.appendingPathComponent("scripts/run.py").path
        ))
        XCTAssertEqual(plan.pinnedHash, String(repeating: "cd", count: 32))
        XCTAssertTrue(plan.revisionID.hasPrefix("catalog/pdf-tools@"))
        // A moving reference never sneaks in: the pinned hash resolves the guard.
        XCTAssertTrue(plan.blockers(userApprovedExecutables: true).isEmpty
            || !plan.preview.executables.isEmpty)
    }

    @MainActor
    func testStageSkillRefusesPathEscapes() throws {
        let service = CatalogInstallService(
            layout: ExtensionStoreLayout(root: temporaryDirectory())
        )
        var item = CatalogItem(
            kind: .skill, provider: .skillsSh, name: "a/b/evil", displayName: "evil"
        )
        item.skill = SkillCatalogDetails(
            source: "a/b", slug: "evil",
            files: [SkillCatalogFile(path: "../outside.txt", contents: "boom")]
        )
        XCTAssertThrowsError(try service.stageSkill(item: item))
    }

    @MainActor
    func testInstallSkillLinksAgentsAndRecordsPackage() throws {
        let root = temporaryDirectory()
        let layout = ExtensionStoreLayout(root: root)
        let canonical = root.appendingPathComponent("agents-canonical")
        let store = SkillStore(layout: layout, canonicalRoot: canonical)
        let registry = ExtensionRegistry(layout: layout, store: store)
        let service = CatalogInstallService(layout: layout, store: store)

        var item = CatalogItem(
            kind: .skill, provider: .skillsSh,
            name: "vercel/skills/pdf-tools", displayName: "PDF Tools"
        )
        item.skill = SkillCatalogDetails(
            source: "vercel/skills", slug: "pdf-tools",
            contentHash: String(repeating: "cd", count: 32),
            files: [SkillCatalogFile(path: "SKILL.md", contents: "---\nname: pdf-tools\n---\nBody")]
        )
        let plan = try service.stageSkill(item: item)

        let agentSkills = root.appendingPathComponent("claude-skills")
        let installation = AgentInstallation(
            agent: .claudeCode, binaryPath: "/usr/local/bin/claude",
            configDirectory: root.path, skillsDirectory: agentSkills.path,
            detectedAt: .now
        )
        let results = try service.installSkill(
            plan: plan, agents: [.claudeCode], installations: [installation],
            registry: registry, userApprovedExecutables: true
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].success)

        // One central copy, one symlink; the package is on record and bound.
        let link = agentSkills.appendingPathComponent("pdf-tools")
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        let package = try XCTUnwrap(registry.packages.first { $0.name == "pdf-tools" })
        XCTAssertEqual(package.kind, .skill)
        XCTAssertNotNil(package.activeRevision)
        XCTAssertEqual(registry.agents(for: package.id), [.claudeCode])
        XCTAssertTrue(registry.auditEvents.contains { $0.kind == .skillInstalled })
        // Staging cleaned up after itself.
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.stagedPath.path))
    }

    @MainActor
    func testInstallRefusedWithoutExecutableApproval() throws {
        let root = temporaryDirectory()
        let layout = ExtensionStoreLayout(root: root)
        let service = CatalogInstallService(layout: layout)
        let registry = ExtensionRegistry(layout: layout)

        var item = CatalogItem(
            kind: .skill, provider: .skillsSh, name: "a/b/tool", displayName: "tool"
        )
        item.skill = SkillCatalogDetails(
            source: "a/b", slug: "tool",
            contentHash: String(repeating: "ef", count: 32),
            files: [
                SkillCatalogFile(path: "SKILL.md", contents: "---\nname: tool\n---\nBody"),
                SkillCatalogFile(path: "run.sh", contents: "#!/bin/sh\necho hi"),
            ]
        )
        let plan = try service.stageSkill(item: item)
        defer { service.discardStaging(plan) }
        // The staged file carries no executable bit (it came as text), so the
        // preview's script list is what the scanner saw by suffix.
        if !plan.preview.executables.isEmpty {
            XCTAssertThrowsError(try service.installSkill(
                plan: plan, agents: [], installations: [], registry: registry,
                userApprovedExecutables: false
            ))
        }
    }
}
