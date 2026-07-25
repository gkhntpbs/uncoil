import XCTest
@testable import Uncoil

final class BumblebeeInstallerTests: XCTestCase {
    private var root: URL!

    private let releaseJSON = """
    {
      "tag_name": "v0.1.2",
      "assets": [
        {"name": "bumblebee_0.1.2_darwin_arm64.tar.gz",
         "browser_download_url": "https://example.invalid/arm64.tar.gz"},
        {"name": "bumblebee_0.1.2_darwin_amd64.tar.gz",
         "browser_download_url": "https://example.invalid/amd64.tar.gz"},
        {"name": "checksums.txt",
         "browser_download_url": "https://example.invalid/checksums.txt"}
      ]
    }
    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncoilBumblebeeInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheReleaseIsParsedAndTheRightArchitecturePicked() throws {
        let release = try XCTUnwrap(
            BumblebeeInstaller.parseRelease(Data(releaseJSON.utf8))
        )
        XCTAssertEqual(release.tag, "v0.1.2")
        XCTAssertEqual(
            release.macAsset(architecture: "arm64")?.name,
            "bumblebee_0.1.2_darwin_arm64.tar.gz"
        )
        XCTAssertEqual(
            release.macAsset(architecture: "amd64")?.name,
            "bumblebee_0.1.2_darwin_amd64.tar.gz"
        )
        XCTAssertNil(release.macAsset(architecture: "riscv"))
        XCTAssertNotNil(release.asset(named: "checksums.txt"))
    }

    func testChecksumsFileIsReadInGoreleaserFormat() {
        let parsed = BumblebeeInstaller.checksums("""
        abc123  bumblebee_0.1.2_darwin_arm64.tar.gz
        def456 *bumblebee_0.1.2_linux_amd64.tar.gz
        bozuk-satır
        """)
        XCTAssertEqual(parsed["bumblebee_0.1.2_darwin_arm64.tar.gz"], "abc123")
        XCTAssertEqual(parsed["bumblebee_0.1.2_linux_amd64.tar.gz"], "def456")
        XCTAssertEqual(parsed.count, 2)
    }

    /// The archive is what the release says it is, or it never reaches the tools
    /// directory.
    func testADownloadThatDoesNotMatchTheChecksumIsRefused() async throws {
        let archive = Data("not really a tarball".utf8)
        let installer = BumblebeeInstaller(
            destinationDirectory: root,
            architecture: "arm64",
            fetch: { url, _ in
                if url == BumblebeeInstaller.releasesURL { return Data(self.releaseJSON.utf8) }
                if url.absoluteString.hasSuffix("checksums.txt") {
                    return Data("0000  bumblebee_0.1.2_darwin_arm64.tar.gz\n".utf8)
                }
                return archive
            },
            extract: { _, _ in XCTFail("mismatched archive is never unpacked") }
        )
        do {
            _ = try await installer.install()
            XCTFail("beklenen hata atılmadı")
        } catch let error as BumblebeeInstaller.InstallError {
            guard case .checksumMismatch = error else {
                return XCTFail("beklenmeyen hata: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: installer.binaryPath.path),
            "reddedilen indirme hiçbir şey yazmaz"
        )
    }

    func testAMissingChecksumStopsTheInstall() async throws {
        let installer = BumblebeeInstaller(
            destinationDirectory: root,
            architecture: "arm64",
            fetch: { url, _ in
                url == BumblebeeInstaller.releasesURL
                    ? Data(self.releaseJSON.utf8)
                    : Data("0000  başka-dosya.tar.gz\n".utf8)
            },
            extract: { _, _ in XCTFail("nothing to unpack") }
        )
        do {
            _ = try await installer.install()
            XCTFail("beklenen hata atılmadı")
        } catch let error as BumblebeeInstaller.InstallError {
            guard case .checksumMissing = error else {
                return XCTFail("beklenmeyen hata: \(error)")
            }
        }
    }

    func testAVerifiedArchiveIsUnpackedAndTheBinaryInstalledExecutable() async throws {
        let archive = Data("tarball bytes".utf8)
        let digest = BumblebeeInstaller.sha256(archive)
        let installer = BumblebeeInstaller(
            destinationDirectory: root.appendingPathComponent("tools", isDirectory: true),
            architecture: "arm64",
            fetch: { url, _ in
                if url == BumblebeeInstaller.releasesURL { return Data(self.releaseJSON.utf8) }
                if url.absoluteString.hasSuffix("checksums.txt") {
                    return Data("\(digest)  bumblebee_0.1.2_darwin_arm64.tar.gz\n".utf8)
                }
                return archive
            },
            extract: { _, directory in
                // Stands in for tar: writes the binary the archive would contain.
                let nested = directory.appendingPathComponent("dist", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: nested, withIntermediateDirectories: true
                )
                let binary = nested.appendingPathComponent("bumblebee")
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
                // The real release ships its rules beside the binary.
                let rules = nested.appendingPathComponent("threat_intel", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: rules, withIntermediateDirectories: true
                )
                try Data("{}".utf8).write(to: rules.appendingPathComponent("rules.json"))
            }
        )
        let installed = try await installer.install()
        XCTAssertEqual(installed.releaseTag, "v0.1.2")
        XCTAssertEqual(installed.sha256, digest)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        XCTAssertEqual(installed.path, installer.binaryPath.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installer.destinationDirectory
                .appendingPathComponent("threat_intel/rules.json").path
        ), "kurallar binary'nin yanında kalır")
    }

    func testTheBinaryIsFoundWhereverTheArchivePutIt() throws {
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("bumblebee"))
        XCTAssertEqual(
            BumblebeeInstaller.findBinary(in: root)?.resolvingSymlinksInPath().path,
            nested.appendingPathComponent("bumblebee").resolvingSymlinksInPath().path
        )
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(BumblebeeInstaller.findBinary(in: empty))
    }
}
