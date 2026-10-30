import Foundation

extension AgentBrowserAdapter {
    static let recommendedVersion = "0.39.4"

    enum Generation: Equatable {
        case playwright
        case native
    }

    static func generation(binary: String) -> Generation {
        runtimeRevision(binary: binary) == nil ? .native : .playwright
    }

    static func installedVersion(binary: String) -> String? {
        if let version = packageVersion(binary: binary) { return version }
        let modified = (try? FileManager.default.attributesOfItem(atPath: binary))?[.modificationDate] as? Date
        let key = "\(binary)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let cached = versionCache.value(for: key) { return cached }
        let result = ProcessRunner.run(executable: binary, arguments: ["--version"], timeout: 5)
        let version = result.launched && !result.timedOut && result.exitCode == 0
            ? parseVersion(result.stdoutString) : nil
        versionCache.store(version, for: key)
        return version
    }

    private static let versionCache = VersionCache()

    private final class VersionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: String?] = [:]

        func value(for key: String) -> String?? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ value: String?, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.updateValue(value, forKey: key)
        }
    }

    static func packageVersion(binary: String) -> String? {
        struct Package: Decodable { var name: String; var version: String }
        let url = packageRoot(binary: binary).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let package = try? JSONDecoder().decode(Package.self, from: data),
              package.name == binaryName
        else { return nil }
        return package.version
    }

    static func parseVersion(_ text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.hasPrefix("v") ? String($0.dropFirst()) : String($0) }
            .first { versionComponents($0) != nil }
    }

    static func versionComponents(_ version: String) -> [Int]? {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    static func isOutdated(_ installed: String?, recommended: String = recommendedVersion) -> Bool {
        guard let installed,
              let have = versionComponents(installed),
              let want = versionComponents(recommended)
        else { return false }
        for index in 0..<max(have.count, want.count) {
            let a = index < have.count ? have[index] : 0
            let b = index < want.count ? want[index] : 0
            if a != b { return a < b }
        }
        return false
    }
    static var nativeBrowserDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-browser/browsers", isDirectory: true)
    }

    static let autoDetectedBrowsers = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    ]

    static func nativeRuntimeInstalled(
        browserDirectory: URL = nativeBrowserDirectory,
        detected: [String] = autoDetectedBrowsers
    ) -> Bool {
        let manager = FileManager.default
        if detected.contains(where: { manager.isExecutableFile(atPath: $0) }) { return true }
        guard let entries = manager.enumerator(at: browserDirectory,
                                               includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in entries {
            if url.lastPathComponent == "Google Chrome for Testing",
               manager.isExecutableFile(atPath: url.path) { return true }
        }
        return false
    }
    static func updateInvocation(binary: String) -> (executable: String, arguments: [String])? {
        if packageVersion(binary: binary) != nil {
            let sibling = URL(fileURLWithPath: binary)
                .deletingLastPathComponent()
                .appendingPathComponent("npm").path
            let npm = FileManager.default.isExecutableFile(atPath: sibling)
                ? sibling : SettingsStore.which("npm")
            guard let npm else { return nil }
            return (npm, ["install", "-g", "\(binaryName)@\(recommendedVersion)"])
        }
        guard generation(binary: binary) == .native else { return nil }
        return (binary, ["upgrade"])
    }
}
