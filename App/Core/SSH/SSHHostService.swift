import Foundation

/// Where the SSH hosts meet the disk: reading the user's config, writing
/// Uncoil's own, and opening a terminal on one.
///
/// The hosts themselves — and which project uses which — live in
/// `ProjectStore`, next to the projects they are associated with. This only
/// keeps what was found on the last scan, which is never persisted: the user's
/// config is the authority for its own hosts, so it is read again whenever the
/// SSH page appears rather than remembered.
@MainActor
final class SSHHostService: ObservableObject {
    static let shared = SSHHostService()

    @Published private(set) var discovered: [SSHConfigEntry] = []
    @Published private(set) var includeStatus: SSHConfigWriter.IncludeStatus = .missing

    let writer: SSHConfigWriter

    init(sshDirectory: URL = SSHConfigWriter.defaultSSHDirectory()) {
        writer = SSHConfigWriter(sshDirectory: sshDirectory)
    }

    private var parser: SSHConfigParser {
        SSHConfigParser(
            sshDirectory: writer.sshDirectory,
            excludedPaths: [writer.uncoilConfigURL.standardizedFileURL.path])
    }

    /// Reads the user's config again and refreshes the hosts Uncoil remembers
    /// from it.
    func rescan(store: ProjectStore) {
        discovered = parser.parse()
        includeStatus = writer.includeStatus()
        store.refreshSystemHosts(from: discovered)
    }

    func entry(for alias: String) -> SSHConfigEntry? {
        discovered.first { $0.alias == alias }
    }

    /// Hosts in the user's config that Uncoil does not remember yet.
    func importable(store: ProjectStore) -> [SSHConfigEntry] {
        discovered.filter { store.sshHost(alias: $0.alias) == nil }
    }

    func importHosts(_ entries: [SSHConfigEntry], store: ProjectStore) {
        for entry in entries where store.sshHost(alias: entry.alias) == nil {
            store.saveSSHHost(entry.asHost)
        }
    }

    enum SaveError: LocalizedError, Equatable {
        case invalidAlias
        case systemConflict(String)
        case duplicate
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidAlias:
                String(localized: "An alias is one word, without spaces or the pattern characters * ? !.")
            case .systemConflict(let path):
                String(localized: "This alias is already defined in \(path). OpenSSH would use that definition, so this one is not saved. Pick another alias, or import the existing host instead.")
            case .duplicate:
                String(localized: "Uncoil already has a host with this alias.")
            case .writeFailed:
                String(localized: "Could not write ~/.ssh/uncoil_config.")
            }
        }
    }

    /// Why an Uncoil host with this alias cannot be saved; nil when it can.
    func validate(_ host: SSHHost, replacing previousAlias: String?, store: ProjectStore) -> SaveError? {
        guard SSHHost.isValidAlias(host.alias) else { return .invalidAlias }
        if let entry = entry(for: host.alias) {
            return .systemConflict(entry.sourcePath.abbreviatingHome)
        }
        if host.alias != previousAlias, store.sshHost(alias: host.alias) != nil { return .duplicate }
        return nil
    }

    func save(_ host: SSHHost, replacing previousAlias: String?, store: ProjectStore) throws {
        if host.origin == .uncoil {
            if let error = validate(host, replacing: previousAlias, store: store) { throw error }
            store.saveSSHHost(host, replacing: previousAlias)
            guard writer.writeUncoilConfig(store.sshHosts) else { throw SaveError.writeFailed }
        } else {
            // A system host's connection is the user's config's to say; only
            // the note is Uncoil's.
            guard var existing = store.sshHost(alias: host.alias) else { return }
            existing.note = host.note
            store.saveSSHHost(existing)
        }
    }

    func delete(alias: String, store: ProjectStore) {
        let wasUncoil = store.sshHost(alias: alias)?.origin == .uncoil
        store.removeSSHHost(alias: alias)
        if wasUncoil { writer.writeUncoilConfig(store.sshHosts) }
    }

    func installInclude() throws {
        try writer.installInclude()
        includeStatus = writer.includeStatus()
    }

    // MARK: - Opening things

    /// Opens the user's config in their text editor. Uncoil does not edit a
    /// file it did not write; it takes them to the line.
    func revealInConfig(_ entry: SSHConfigEntry) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-t", entry.sourcePath]
        try? process.run()
    }

    /// A plain terminal session in `project` running `ssh <alias>`, focused.
    ///
    /// The same session every terminal is — created through the launcher,
    /// drawn by the same view — whose shell is simply `ssh` instead of a login
    /// shell, so closing the connection closes the session.
    @discardableResult
    func openTerminal(alias: String, in project: Project, store: ProjectStore, settings: SettingsStore) -> SessionRecord {
        var record = SessionLauncher(projects: store, settings: settings).launch(.terminal, in: project)
        store.updateSession(record.id) {
            $0.title = "ssh \(alias)"
            $0.shellCommand = ["ssh", alias]
        }
        record = store.sessions.first { $0.id == record.id } ?? record
        Router.shared.go(to: .session(record.id))
        return record
    }
}

private extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
