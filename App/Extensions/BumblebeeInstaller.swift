import CryptoKit
import Foundation

/// Installs Bumblebee from its own GitHub releases.
///
/// Only the release archive is fetched — never an install script, and nothing is
/// executed to install it. The archive is checked against the `checksums.txt`
/// published with the same release before a single byte reaches Uncoil's tools
/// directory, and a download that does not match is thrown away.
///
/// Every side effect (network, unpacking) is injected, so what is downloaded,
/// what is refused and what is written are all testable without touching the
/// network.
struct BumblebeeInstaller {
    static let repository = "perplexityai/bumblebee"
    static let releasesURL = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!
    /// Where the project is, for the UI to link to.
    static let homepage = URL(string: "https://github.com/\(repository)")!

    struct Asset: Equatable {
        var name: String
        var url: URL
    }

    struct Release: Equatable {
        var tag: String
        var assets: [Asset]

        func asset(named name: String) -> Asset? {
            assets.first { $0.name == name }
        }

        /// The macOS build for this machine's architecture.
        func macAsset(architecture: String) -> Asset? {
            assets.first {
                $0.name.contains("darwin_\(architecture)") && $0.name.hasSuffix(".tar.gz")
            }
        }
    }

    struct Installed: Equatable {
        var path: String
        var releaseTag: String
        var sha256: String
    }

    enum InstallError: LocalizedError, Equatable {
        case releaseUnreadable
        case noBuildForArchitecture(String)
        case checksumMissing(String)
        case checksumMismatch(expected: String, found: String)
        case archiveHasNoBinary
        case notExecutable(String)

        var errorDescription: String? {
            switch self {
            case .releaseUnreadable:
                "The GitHub release information could not be read."
            case .noBuildForArchitecture(let architecture):
                "This release has no macOS \(architecture) build."
            case .checksumMissing(let name):
                "There is no published checksum for \(name); nothing was installed."
            case .checksumMismatch(let expected, let found):
                "The downloaded file does not match the expected checksum"
                    + " (beklenen \(expected.prefix(12))…, bulunan \(found.prefix(12))…);"
                    + " file dropped."
            case .archiveHasNoBinary:
                "No bumblebee binary inside the archive."
            case .notExecutable(let path):
                "\(path) is not executable."
            }
        }
    }

    /// Where the install has got to, for a UI that has to say more than "wait".
    enum Phase: Equatable {
        case askingGitHub
        case downloading(receivedBytes: Int64, totalBytes: Int64?)
        case verifying
        case unpacking
        case installing
        case done(version: String)

        var label: String {
            switch self {
            case .askingGitHub: "Reading the version…"
            case .downloading(let received, let total):
                total.map {
                    "Downloading… \(Self.megabytes(received)) / \(Self.megabytes($0)) MB"
                } ?? "Downloading… \(Self.megabytes(received)) MB"
            case .verifying: "Verifying the checksum…"
            case .unpacking: "Unpacking the archive…"
            case .installing: "Copying into place…"
            case .done(let version): "Kuruldu: \(version)"
            }
        }

        /// 0…1 when it can be known; nil for the steps that have no size.
        var fraction: Double? {
            switch self {
            case .askingGitHub: return 0.05
            case .downloading(let received, let total):
                guard let total, total > 0 else { return nil }
                // Downloading is most of the wait, so it owns most of the bar.
                return 0.1 + 0.7 * Double(received) / Double(total)
            case .verifying: return 0.85
            case .unpacking: return 0.92
            case .installing: return 0.97
            case .done: return 1
            }
        }

        private static func megabytes(_ bytes: Int64) -> String {
            String(format: "%.1f", Double(bytes) / 1_048_576)
        }
    }

    var destinationDirectory: URL
    /// "arm64" or "amd64", as the release names them.
    var architecture: String
    /// Fetches a URL, reporting bytes as they arrive.
    var fetch: (URL, @escaping (Int64, Int64?) -> Void) async throws -> Data
    /// Unpacks a `.tar.gz` into a directory.
    var extract: (URL, URL) throws -> Void

    init(
        destinationDirectory: URL,
        architecture: String = Self.currentArchitecture,
        fetch: ((URL, @escaping (Int64, Int64?) -> Void) async throws -> Data)? = nil,
        extract: ((URL, URL) throws -> Void)? = nil
    ) {
        self.destinationDirectory = destinationDirectory
        self.architecture = architecture
        self.fetch = fetch ?? Self.download
        self.extract = extract ?? Self.untar
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    var binaryPath: URL {
        destinationDirectory.appendingPathComponent("bumblebee")
    }

    // MARK: - Pure parts

    static func parseRelease(_ data: Data) -> Release? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let rawAssets = root["assets"] as? [[String: Any]] else { return nil }
        let assets = rawAssets.compactMap { entry -> Asset? in
            guard let name = entry["name"] as? String,
                  let urlString = entry["browser_download_url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            return Asset(name: name, url: url)
        }
        return Release(tag: tag, assets: assets)
    }

    /// `<sha256>  <filename>` per line, as goreleaser writes it.
    static func checksums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let name = parts[parts.count - 1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            result[name] = String(parts[0]).lowercased()
        }
        return result
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Install

    /// Downloads the newest release, verifies it, and puts the binary in place.
    /// `onPhase` is called on every step so the caller can show real progress.
    func install(onPhase: @escaping (Phase) -> Void = { _ in }) async throws -> Installed {
        onPhase(.askingGitHub)
        let releaseData = try await fetch(Self.releasesURL) { _, _ in }
        guard let release = Self.parseRelease(releaseData) else {
            throw InstallError.releaseUnreadable
        }
        guard let asset = release.macAsset(architecture: architecture) else {
            throw InstallError.noBuildForArchitecture(architecture)
        }
        guard let checksumAsset = release.asset(named: "checksums.txt") else {
            throw InstallError.checksumMissing(asset.name)
        }
        let published = Self.checksums(
            String(decoding: try await fetch(checksumAsset.url) { _, _ in }, as: UTF8.self)
        )
        guard let expected = published[asset.name] else {
            throw InstallError.checksumMissing(asset.name)
        }

        onPhase(.downloading(receivedBytes: 0, totalBytes: nil))
        let archive = try await fetch(asset.url) { received, total in
            onPhase(.downloading(receivedBytes: received, totalBytes: total))
        }
        onPhase(.verifying)
        let digest = Self.sha256(archive)
        guard digest == expected else {
            throw InstallError.checksumMismatch(expected: expected, found: digest)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoil-bumblebee-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archiveURL = staging.appendingPathComponent(asset.name)
        try archive.write(to: archiveURL, options: .atomic)
        onPhase(.unpacking)
        try extract(archiveURL, staging)
        onPhase(.installing)

        guard let unpacked = Self.findBinary(in: staging) else {
            throw InstallError.archiveHasNoBinary
        }
        try FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true
        )
        // The whole payload, not just the binary: the release ships its
        // `threat_intel` rules beside the executable, and separating them would
        // leave Bumblebee looking for files that are not there.
        let payload = unpacked.deletingLastPathComponent()
        for item in (try? FileManager.default.contentsOfDirectory(
            at: payload, includingPropertiesForKeys: nil
        )) ?? [unpacked] {
            let destination = destinationDirectory
                .appendingPathComponent(item.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: item, to: destination)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binaryPath.path
        )
        // A file Uncoil downloaded itself carries no quarantine flag, but a
        // re-used download could; clearing it costs nothing and keeps the first
        // run from being refused by Gatekeeper.
        Self.clearQuarantine(binaryPath)
        guard FileManager.default.isExecutableFile(atPath: binaryPath.path) else {
            throw InstallError.notExecutable(binaryPath.path)
        }
        onPhase(.done(version: release.tag))
        return Installed(path: binaryPath.path, releaseTag: release.tag, sha256: digest)
    }

    /// The `bumblebee` file inside an unpacked archive, wherever the archive put
    /// it.
    static func findBinary(in directory: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == "bumblebee" {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            return url
        }
        return nil
    }

    // MARK: - Real side effects

    /// Streams the body so the caller can show how far along the download is.
    private static func download(
        _ url: URL,
        onBytes: @escaping (Int64, Int64?) -> Void
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Uncoil", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        var data = Data()
        if let total { data.reserveCapacity(Int(total)) }
        var lastReport = 0
        for try await byte in stream {
            data.append(byte)
            // Reporting every byte would cost more than the download.
            if data.count - lastReport >= 64 * 1024 {
                lastReport = data.count
                onBytes(Int64(data.count), total)
            }
        }
        onBytes(Int64(data.count), total)
        return data
    }

    private static func untar(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.archiveHasNoBinary
        }
    }

    private static func clearQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", url.path]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
