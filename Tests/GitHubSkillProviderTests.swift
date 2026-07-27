import XCTest
@testable import Uncoil

/// The GitHub-backed skill catalog provider against recorded API answers —
/// search mapping, multi-query dedup, view windows, multi-skill trees, blob
/// decoding, pinning, and rate-limit behaviour. No network anywhere.
@MainActor
final class GitHubSkillProviderTests: XCTestCase {
    static let searchFixture = Data("""
    {
      "total_count": 2,
      "items": [
        {
          "full_name": "anthropics/skills",
          "name": "skills",
          "owner": { "login": "anthropics" },
          "description": "Agent Skills",
          "stargazers_count": 164342,
          "forks_count": 900,
          "license": { "spdx_id": "MIT" },
          "topics": ["agent-skills", "claude"],
          "archived": false,
          "fork": false,
          "created_at": "2025-09-01T00:00:00Z",
          "pushed_at": "2026-07-20T00:00:00Z",
          "default_branch": "main"
        },
        {
          "full_name": "acme/archived-skills",
          "name": "archived-skills",
          "owner": { "login": "acme" },
          "stargazers_count": 12,
          "archived": true,
          "fork": false
        },
        {
          "full_name": "acme/forked-skills",
          "name": "forked-skills",
          "owner": { "login": "acme" },
          "stargazers_count": 7,
          "archived": false,
          "fork": true
        }
      ]
    }
    """.utf8)

    static let treeFixture = Data("""
    {
      "truncated": false,
      "tree": [
        { "path": "README.md", "type": "blob", "sha": "r1", "size": 100 },
        { "path": "skills/pdf/SKILL.md", "type": "blob", "sha": "s1", "size": 200 },
        { "path": "skills/pdf/scripts/run.py", "type": "blob", "sha": "s2", "size": 50 },
        { "path": "skills/docx/SKILL.md", "type": "blob", "sha": "s3", "size": 180 },
        { "path": "node_modules/x/SKILL.md", "type": "blob", "sha": "n1", "size": 10 },
        { "path": ".github/SKILL.md", "type": "blob", "sha": "h1", "size": 10 },
        { "path": "skills/pdf", "type": "tree", "sha": "t1" }
      ]
    }
    """.utf8)

    private func provider(
        responding: @escaping (URL) throws -> Data,
        token: String? = "gh-token",
        now: Date = ISO8601DateFormatter().date(from: "2026-07-27T00:00:00Z")!
    ) -> GitHubSkillProvider {
        var provider = GitHubSkillProvider(client: CatalogHTTPClient(send: { request in
            let data = try responding(request.url!)
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }))
        provider.token = { token }
        provider.now = { now }
        provider.seeds = [
            .topic("agent-skills"), .topic("claude-skills"),
            .searchQuery("\"SKILL.md\" in:readme"),
        ]
        return provider
    }

    // MARK: - Listing

    func testSearchMapsSkipsArchivedAndForks() async throws {
        let provider = provider(responding: { _ in Self.searchFixture })
        let page = try await provider.page(CatalogQuery(view: .popular))
        // Three queries all return the same fixture; dedup leaves one live repo.
        XCTAssertEqual(page.items.count, 1)
        let item = page.items[0]
        XCTAssertEqual(item.provider, .gitHub)
        XCTAssertEqual(item.name, "anthropics/skills")
        XCTAssertEqual(item.publisher, "anthropics")
        XCTAssertEqual(item.stars, 164342)
        // Stars are stars; installs stay empty for GitHub.
        XCTAssertNil(item.installs)
        XCTAssertEqual(item.license, "MIT")
        XCTAssertEqual(item.skill?.slug, "skills")
        XCTAssertNotNil(item.updatedAt)
    }

    func testAuthHeaderAndPagination() async throws {
        var urls: [String] = []
        var auths: [String?] = []
        var provider = GitHubSkillProvider(client: CatalogHTTPClient(send: { request in
            urls.append(request.url!.absoluteString)
            auths.append(request.value(forHTTPHeaderField: "Authorization"))
            return (Self.searchFixture, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }))
        provider.token = { "device-flow-token" }
        provider.seeds = [.topic("agent-skills")]
        let page = try await provider.page(CatalogQuery(view: .popular, cursor: "2"), perPage: 20)
        XCTAssertTrue(urls[0].contains("page=3"), "cursor 2 → GitHub page 3 (1-based)")
        XCTAssertEqual(auths[0], "Bearer device-flow-token")
        // The fixture has fewer than perPage items → no further page.
        XCTAssertNil(page.nextCursor)
    }

    func testViewQueriesCarryTheirWindows() {
        let now = ISO8601DateFormatter().date(from: "2026-07-27T00:00:00Z")!
        let provider = provider(responding: { _ in Data() }, now: now)

        let trending = provider.searchQueries(view: .trending, search: "")
        XCTAssertTrue(trending.allSatisfy { $0.query.contains("pushed:>=2026-06-27") })
        let newest = provider.searchQueries(view: .newest, search: "")
        XCTAssertTrue(newest.allSatisfy { $0.query.contains("created:>=") })
        let popular = provider.searchQueries(view: .popular, search: "")
        XCTAssertEqual(popular.count, 3)
        XCTAssertTrue(popular.allSatisfy { $0.query.contains("fork:false archived:false") })

        let search = provider.searchQueries(view: .popular, search: "pdf tools")
        XCTAssertEqual(search.count, 2)
        XCTAssertTrue(search[0].query.contains("pdf tools"))
        XCTAssertTrue(search[0].query.contains("SKILL.md"))
    }

    func testRankingIsTransparent() {
        var old = CatalogItem(kind: .skill, provider: .gitHub, name: "a/dormant", displayName: "dormant")
        old.stars = 10_000
        old.updatedAt = ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z")
        var fresh = CatalogItem(kind: .skill, provider: .gitHub, name: "b/busy", displayName: "busy")
        fresh.stars = 900
        fresh.updatedAt = ISO8601DateFormatter().date(from: "2026-07-26T00:00:00Z")

        let provider = provider(responding: { _ in Data() })
        let trending = provider.rank([old, fresh], view: .trending, isSearch: false)
        XCTAssertEqual(trending.first?.name, "b/busy", "recent activity outranks dormant stars")
        let popular = provider.rank([old, fresh], view: .popular, isSearch: false)
        XCTAssertEqual(popular.first?.name, "a/dormant")
    }

    // MARK: - Quality gate

    private func skillItem(
        name: String, description: String?, stars: Int, topics: [String] = ["agent-skills"]
    ) -> CatalogItem {
        var item = CatalogItem(
            kind: .skill, provider: .gitHub,
            name: "owner/\(name)", displayName: name, summary: description
        )
        item.stars = stars
        item.topics = topics
        return item
    }

    func testQualityGateDropsJunk() {
        // No description → out.
        XCTAssertFalse(GitHubSkillProvider.passesQualityGate(
            skillItem(name: "empty", description: nil, stars: 500), isSearch: false
        ))
        // No skill signal anywhere → out.
        XCTAssertFalse(GitHubSkillProvider.passesQualityGate(
            skillItem(name: "video-maker", description: "Generate videos", stars: 900, topics: []),
            isSearch: false
        ))
        // Awesome-list index → out.
        XCTAssertFalse(GitHubSkillProvider.passesQualityGate(
            skillItem(name: "awesome-skills", description: "A list of agent skills", stars: 5000),
            isSearch: false
        ))
        // Predominantly CJK description → out.
        XCTAssertFalse(GitHubSkillProvider.passesQualityGate(
            skillItem(name: "turbo", description: "利用AI大模型一键生成高清短视频 skill", stars: 90_000),
            isSearch: false
        ))
        // Nearly no stars while browsing → out; while searching → in.
        let tiny = skillItem(name: "my-skill", description: "An agent skill for PDFs", stars: 0)
        XCTAssertFalse(GitHubSkillProvider.passesQualityGate(tiny, isSearch: false))
        XCTAssertTrue(GitHubSkillProvider.passesQualityGate(tiny, isSearch: true))
        // The ordinary good case stays in.
        XCTAssertTrue(GitHubSkillProvider.passesQualityGate(
            skillItem(name: "pdf-skills", description: "Skills for reading PDFs", stars: 40),
            isSearch: false
        ))
    }

    func testCjkRatio() {
        XCTAssertEqual(GitHubSkillProvider.cjkRatio(of: "plain english words"), 0)
        XCTAssertGreaterThan(GitHubSkillProvider.cjkRatio(of: "生成高清短视频"), 0.9)
        XCTAssertLessThan(GitHubSkillProvider.cjkRatio(of: "PDF tools 支持 fill and read forms"), 0.25)
    }

    // MARK: - Trees and skills

    func testTreeYieldsEverySkillButNotHiddenOnes() throws {
        let tree = try JSONDecoder().decode(
            GitHubSkillProvider.TreeResponse.self, from: Self.treeFixture
        )
        let locations = GitHubSkillProvider.skillLocations(in: tree, repoName: "skills")
        XCTAssertEqual(locations.map(\.directory), ["skills/docx", "skills/pdf"])
        XCTAssertEqual(locations.map(\.slug), ["docx", "pdf"])
    }

    func testRootSkillIsItsOwnLocation() throws {
        let tree = GitHubSkillProvider.TreeResponse(tree: [
            .init(path: "SKILL.md", type: "blob", sha: "x", size: 10),
            .init(path: "scripts/a.py", type: "blob", sha: "y", size: 10),
        ], truncated: false)
        let locations = GitHubSkillProvider.skillLocations(in: tree, repoName: "MySkill")
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations[0].directory, "")
        XCTAssertEqual(locations[0].slug, "myskill")
    }

    func testDetailResolvesCommitFilesAndFrontMatter() async throws {
        let skillMD = "---\nname: PDF Tools\ndescription: Fill and read PDFs\n---\nBody"
        let provider = provider(responding: { url in
            let path = url.absoluteString
            if path.hasSuffix("/repos/acme/skills") {
                return Data("""
                { "full_name": "acme/skills", "name": "skills", "owner": {"login":"acme"},
                  "stargazers_count": 5, "archived": false, "fork": false, "default_branch": "main" }
                """.utf8)
            }
            if path.contains("/commits/main") { return Data("{ \"sha\": \"abc1234567890def\" }".utf8) }
            if path.contains("/git/trees/") {
                return Data("""
                { "tree": [
                    { "path": "skills/pdf/SKILL.md", "type": "blob", "sha": "b1", "size": 80 },
                    { "path": "skills/pdf/assets/logo.bin", "type": "blob", "sha": "b2", "size": 4 }
                ], "truncated": false }
                """.utf8)
            }
            if path.contains("/git/blobs/b1") {
                let encoded = Data(skillMD.utf8).base64EncodedString()
                return Data("{ \"content\": \"\(encoded)\", \"encoding\": \"base64\" }".utf8)
            }
            if path.contains("/git/blobs/b2") {
                // Bytes that are not valid UTF-8: must survive as binary.
                let encoded = Data([0xFF, 0xD8, 0x00, 0x81]).base64EncodedString()
                return Data("{ \"content\": \"\(encoded)\", \"encoding\": \"base64\" }".utf8)
            }
            throw URLError(.unsupportedURL)
        })
        var item = CatalogItem(kind: .skill, provider: .gitHub, name: "acme/skills", displayName: "skills")
        item.repository = "acme/skills"
        let full = try await provider.detail(for: item)

        XCTAssertEqual(full.skill?.commitSHA, "abc1234567890def")
        XCTAssertEqual(full.skill?.directory, "skills/pdf")
        XCTAssertEqual(full.skill?.availableSkills.count, 1)
        XCTAssertEqual(full.displayName, "PDF Tools")
        XCTAssertEqual(full.summary, "Fill and read PDFs")
        let files = try XCTUnwrap(full.skill?.files)
        XCTAssertEqual(files.map(\.path).sorted(), ["SKILL.md", "assets/logo.bin"])
        let binary = try XCTUnwrap(files.first { $0.path == "assets/logo.bin" })
        XCTAssertEqual(binary.binaryContents, Data([0xFF, 0xD8, 0x00, 0x81]))
    }

    func testRepoWithoutSkillMDIsNotInstallable() async {
        let provider = provider(responding: { url in
            let path = url.absoluteString
            if path.hasSuffix("/repos/acme/empty") {
                return Data("{ \"full_name\": \"acme/empty\", \"name\": \"empty\", \"default_branch\": \"main\", \"archived\": false, \"fork\": false }".utf8)
            }
            if path.contains("/commits/main") { return Data("{ \"sha\": \"deadbeef\" }".utf8) }
            if path.contains("/git/trees/") {
                return Data("{ \"tree\": [ { \"path\": \"README.md\", \"type\": \"blob\", \"sha\": \"r\", \"size\": 5 } ], \"truncated\": false }".utf8)
            }
            throw URLError(.unsupportedURL)
        })
        var item = CatalogItem(kind: .skill, provider: .gitHub, name: "acme/empty", displayName: "empty")
        item.repository = "acme/empty"
        do {
            _ = try await provider.detail(for: item)
            XCTFail("should have thrown")
        } catch let error as CatalogError {
            guard case .malformed = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testArchivedRepoIsRefusedAtDetail() async {
        let provider = provider(responding: { url in
            if url.absoluteString.hasSuffix("/repos/acme/old") {
                return Data("{ \"full_name\": \"acme/old\", \"name\": \"old\", \"archived\": true }".utf8)
            }
            throw URLError(.unsupportedURL)
        })
        var item = CatalogItem(kind: .skill, provider: .gitHub, name: "acme/old", displayName: "old")
        item.repository = "acme/old"
        do {
            _ = try await provider.detail(for: item)
            XCTFail("should have thrown")
        } catch { /* expected */ }
    }

    // MARK: - Rate limits

    func testGitHub403BecomesRateLimitedWithStaleFallback() async throws {
        let cache = CatalogDiskCache(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("gh-tests-\(UUID().uuidString)")
        )
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let url = URL(string: "https://api.github.com/search/repositories?q=x")!

        var clock = Date.now
        let limited = CatalogHTTPClient(
            send: { request in
                (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil
                )!)
            },
            cache: cache,
            now: { clock }
        )
        // Nothing cached: the throttle surfaces as its own error.
        do {
            _ = try await limited.get(url, ttl: 0)
            XCTFail("should have thrown")
        } catch CatalogError.rateLimited {
        } catch { XCTFail("wrong error: \(error)") }

        // With an old copy on disk, throttling serves it, marked stale.
        cache.write(Self.searchFixture, for: url)
        clock = clock.addingTimeInterval(3600)
        let response = try await limited.get(url, ttl: 600)
        XCTAssertTrue(response.isStaleFallback)
    }

    // MARK: - Update pinning

    func testCommitPinDrivesUpdateDetection() {
        var item = CatalogItem(kind: .skill, provider: .gitHub, name: "acme/skills", displayName: "skills")
        item.skill = SkillCatalogDetails(
            source: "acme/skills", slug: "pdf", commitSHA: "abc1234567890def", directory: "skills/pdf"
        )
        let installedAtPin = ExtensionPackage(
            id: "catalog:gitHub:acme/skills", kind: .skill, name: "pdf",
            source: .adopted(path: "/tmp/x"),
            activeRevision: InstalledRevision(
                id: "catalog/pdf@abc123456789",
                contentHash: "h", path: "/tmp/x", installedAt: .now
            )
        )
        // Same pin prefix (12 chars) → installed.
        XCTAssertEqual(
            CatalogStore.installedState(of: item, packages: [installedAtPin]), .installed
        )
        var moved = item
        moved.skill?.commitSHA = "fff9999999999999"
        XCTAssertEqual(
            CatalogStore.installedState(of: item.kind == .skill ? moved : item, packages: [installedAtPin]),
            .updateAvailable
        )
    }
}
