import Foundation

/// Writes the hosts Uncoil owns, and nothing the user owns without asking.
///
/// Uncoil's hosts go to `~/.ssh/uncoil_config`, a file Uncoil rewrites whole.
/// The user's `~/.ssh/config` is touched exactly once, when they confirm it:
/// one marked `Include uncoil_config` line goes at the very top. The top,
/// because OpenSSH takes the first value it sees for every option, and an
/// `Include` written after a `Host` block only applies inside that block.
struct SSHConfigWriter {
    static let uncoilConfigName = "uncoil_config"
    static let includeMarker = "# Added by Uncoil: hosts managed in Uncoil (Settings > SSH Hosts)"
    static let includeLine = "Include \(uncoilConfigName)"

    var sshDirectory: URL

    var configURL: URL { sshDirectory.appendingPathComponent("config") }
    var uncoilConfigURL: URL { sshDirectory.appendingPathComponent(Self.uncoilConfigName) }
    var backupURL: URL { sshDirectory.appendingPathComponent("config.bak") }

    static func defaultSSHDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    // MARK: - Uncoil's own file

    static func render(_ hosts: [SSHHost]) -> String {
        var lines = [
            "# Managed by Uncoil. Edit these hosts in Uncoil (Settings > SSH Hosts);",
            "# changes made here are overwritten.",
        ]
        for host in hosts where host.origin == .uncoil {
            lines.append("")
            if let note = host.trimmedNote {
                lines.append("# \(note.replacingOccurrences(of: "\n", with: " "))")
            }
            lines.append("Host \(host.alias)")
            if let value = host.hostName, !value.isEmpty { lines.append("    HostName \(quoted(value))") }
            if let value = host.user, !value.isEmpty { lines.append("    User \(quoted(value))") }
            if let port = host.port { lines.append("    Port \(port)") }
            if let value = host.identityFile, !value.isEmpty {
                lines.append("    IdentityFile \(quoted(value))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    func writeUncoilConfig(_ hosts: [SSHHost]) -> Bool {
        ensureDirectory()
        guard let data = Self.render(hosts).data(using: .utf8),
              AtomicFile.write(data, to: uncoilConfigURL) else { return false }
        // OpenSSH refuses a config others can write; keep it the user's alone.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: uncoilConfigURL.path)
        return true
    }

    // MARK: - The Include line

    enum IncludeStatus: Equatable {
        /// At the top, before any `Host` or `Match`: Uncoil's hosts resolve.
        case installed
        /// Present, but after a `Host` or `Match` line, so it only applies
        /// inside that block.
        case misplaced
        case missing
    }

    func includeStatus() -> IncludeStatus {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return .missing }
        return Self.includeStatus(in: text)
    }

    static func includeStatus(in text: String) -> IncludeStatus {
        var sawBlock = false
        for line in text.components(separatedBy: .newlines) {
            guard let (keyword, arguments) = SSHConfigParser.split(line) else { continue }
            if keyword == "host" || keyword == "match" { sawBlock = true }
            if keyword == "include", arguments.contains(where: Self.namesUncoilConfig) {
                return sawBlock ? .misplaced : .installed
            }
        }
        return .missing
    }

    private static func namesUncoilConfig(_ argument: String) -> Bool {
        argument == uncoilConfigName || argument == "~/.ssh/\(uncoilConfigName)"
            || argument.hasSuffix("/.ssh/\(uncoilConfigName)")
    }

    enum WriteError: LocalizedError {
        case backupFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .backupFailed: String(localized: "Could not back up your SSH config, so it was not changed.")
            case .writeFailed: String(localized: "Could not write your SSH config.")
            }
        }
    }

    /// Puts the marked `Include` at the top of `~/.ssh/config`, once.
    ///
    /// Idempotent: a config that already includes Uncoil's file is left as it
    /// is, byte for byte. Otherwise the previous file is copied to
    /// `config.bak` first, and its permissions are kept.
    func installInclude() throws {
        ensureDirectory()
        let manager = FileManager.default
        let existing = try? String(contentsOf: configURL, encoding: .utf8)
        if let existing, Self.includeStatus(in: existing) == .installed { return }
        var permissions: Any = NSNumber(value: 0o600)
        if existing != nil {
            permissions = (try? manager.attributesOfItem(atPath: configURL.path))?[.posixPermissions]
                ?? permissions
            try? manager.removeItem(at: backupURL)
            do {
                try manager.copyItem(at: configURL, to: backupURL)
            } catch {
                throw WriteError.backupFailed
            }
        }
        let updated = Self.insertingInclude(into: existing ?? "")
        guard let data = updated.data(using: .utf8), AtomicFile.write(data, to: configURL) else {
            throw WriteError.writeFailed
        }
        try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: configURL.path)
    }

    static func insertingInclude(into text: String) -> String {
        let header = "\(includeMarker)\n\(includeLine)\n"
        return text.isEmpty ? header : header + "\n" + text
    }

    // MARK: -

    private func ensureDirectory() {
        guard !FileManager.default.fileExists(atPath: sshDirectory.path) else { return }
        try? FileManager.default.createDirectory(
            at: sshDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private static func quoted(_ value: String) -> String {
        value.contains(where: { $0 == " " || $0 == "\t" }) ? "\"\(value)\"" : value
    }
}
