import Foundation

/// Where a new extension can come from.
enum ExtensionDiscoverySource: Equatable, Codable, Identifiable {
    case localFolder(path: String)
    case gitHubRepository(repository: String, subpath: String?, reference: String?)
    case gitHubRelease(repository: String, tag: String, asset: String?)
    /// A list Uncoil (or the user) curates: name plus where the list lives.
    case curatedRegistry(name: String, url: String)
    /// What an agent already has in its own skills directory.
    case agentSkillsDirectory(agent: ExtensionAgentID, path: String)
    case bundled(identifier: String)

    var id: String {
        switch self {
        case .localFolder(let path): "local:\(path)"
        case .gitHubRepository(let repository, let subpath, let reference):
            "github:\(repository):\(subpath ?? "")@\(reference ?? "")"
        case .gitHubRelease(let repository, let tag, let asset):
            "release:\(repository):\(tag):\(asset ?? "")"
        case .curatedRegistry(let name, let url): "registry:\(name):\(url)"
        case .agentSkillsDirectory(let agent, let path): "agent:\(agent.rawValue):\(path)"
        case .bundled(let identifier): "bundled:\(identifier)"
        }
    }

    var label: String {
        switch self {
        case .localFolder(let path): "Yerel klasör · \(path)"
        case .gitHubRepository(let repository, _, let reference):
            "GitHub · \(repository)\(reference.map { " @\($0)" } ?? "")"
        case .gitHubRelease(let repository, let tag, _): "GitHub release · \(repository) \(tag)"
        case .curatedRegistry(let name, _): "Registry · \(name)"
        case .agentSkillsDirectory(let agent, _): "\(agent.displayName) skill dizini"
        case .bundled: "Uncoil ile gelen"
        }
    }

    /// The source class this would become once installed. Discovery does not
    /// promote anything: a local folder stays unmanaged.
    var installedSource: ExtensionSource? {
        switch self {
        case .localFolder(let path), .agentSkillsDirectory(_, let path):
            .local(path: path)
        case .gitHubRepository(let repository, let subpath, let reference):
            .managedGitHub(
                repository: repository, subpath: subpath,
                tracking: .branch(reference ?? "main")
            )
        case .gitHubRelease(let repository, let tag, _):
            .managedGitHub(repository: repository, subpath: nil, tracking: .tag(tag))
        case .bundled(let identifier):
            .bundled(identifier: identifier)
        case .curatedRegistry:
            // A registry is a catalogue, not an extension: an entry from it names
            // its own repository, and that is what gets installed.
            nil
        }
    }
}

/// One entry from a curated registry.
struct CuratedRegistryEntry: Equatable, Codable, Identifiable {
    var name: String
    var kind: ExtensionKind
    var repository: String
    var subpath: String?
    var summary: String?
    var license: String?

    var id: String { "\(repository)/\(name)" }

    var source: ExtensionDiscoverySource {
        .gitHubRepository(repository: repository, subpath: subpath, reference: nil)
    }
}

/// Everything shown before an extension is installed.
///
/// Assembled from what can actually be checked. A field nothing answered stays
/// nil and is displayed as unknown, because "we did not look" and "there is
/// nothing" are different facts.
struct ExtensionInstallPreview: Equatable {
    struct Commit: Equatable {
        var sha: String
        var subject: String
        var date: Date?

        var shortSHA: String { String(sha.prefix(12)) }
    }

    var name: String
    var kind: ExtensionKind
    var source: ExtensionDiscoverySource
    /// Repository owner, when the source has one.
    var owner: String?
    var license: String?
    var lastCommit: Commit?
    /// What is being followed: a branch, a tag, or nothing for a local folder.
    var tracking: String?
    var subpath: String?
    var scripts: [String] = []
    var binaries: [String] = []
    /// Permissions the extension's own manifest asks for.
    var requestedPermissions: [String] = []
    var supportedAgents: [ExtensionAgentID] = []
    var findings: [SecurityFinding] = []
    /// Bumblebee's own summary, kept separate from Uncoil's findings.
    var bumblebeeSummary: String?
    /// The exact commit that would be installed. `nil` means it was not resolved
    /// yet, which is itself a reason not to install.
    var resolvedCommit: String?
    var diff: [ExtensionAdoptionService.FileChange] = []

    var executables: [String] { scripts + binaries }

    var blockingFindings: [SecurityFinding] {
        findings.filter { $0.severity == .blocked }
    }

    var changedFiles: [ExtensionAdoptionService.FileChange] {
        diff.filter { $0.kind != .unchanged }
    }
}

/// Builds the preview from a materialised copy of the extension.
enum ExtensionInstallPreviewBuilder {
    /// Names that hold a licence, in the order they are believed.
    static let licenseFileNames = ["LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"]

    static func owner(of repository: String) -> String? {
        let parts = repository.split(separator: "/")
        return parts.count == 2 ? String(parts[0]) : nil
    }

    /// SPDX identifier when the licence file names one, else the file's name.
    static func license(at root: URL) -> String? {
        for name in licenseFileNames {
            let url = root.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if let identifier = spdxIdentifier(in: text) { return identifier }
            return name
        }
        return nil
    }

    static func spdxIdentifier(in text: String) -> String? {
        for line in text.components(separatedBy: "\n").prefix(20) {
            if let range = line.range(of: "SPDX-License-Identifier:") {
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
            let upper = line.uppercased()
            for known in ["MIT LICENSE", "APACHE LICENSE", "BSD ", "GNU GENERAL PUBLIC LICENSE"]
            where upper.contains(known) {
                return known == "GNU GENERAL PUBLIC LICENSE"
                    ? "GPL"
                    : known.replacingOccurrences(of: " LICENSE", with: "")
                        .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Scripts and binaries, split so the UI can say which is which.
    @MainActor
    static func executables(at root: URL) -> (scripts: [String], binaries: [String]) {
        let all = ExtensionUpdateEngine.executables(at: root)
        let scriptSuffixes = [".sh", ".bash", ".zsh", ".py", ".rb", ".js", ".mjs", ".ts"]
        var scripts: [String] = []
        var binaries: [String] = []
        for path in all {
            if scriptSuffixes.contains(where: { path.hasSuffix($0) }) {
                scripts.append(path)
            } else {
                binaries.append(path)
            }
        }
        return (scripts.sorted(), binaries.sorted())
    }

    /// Assembles the preview from a materialised copy plus what the caller
    /// already knows from git.
    ///
    /// The git facts are passed in rather than fetched here: whoever owns the
    /// mirror has them, and this stays a pure read of the files on disk.
    @MainActor
    static func preview(
        name: String,
        kind: ExtensionKind,
        source: ExtensionDiscoverySource,
        materializedPath: URL,
        installedPath: URL?,
        tracking: String?,
        lastCommit: ExtensionInstallPreview.Commit?,
        resolvedCommit: String?,
        findings: [SecurityFinding] = [],
        bumblebeeSummary: String? = nil
    ) -> ExtensionInstallPreview {
        let executables = executables(at: materializedPath)
        let claims = manifestClaims(at: materializedPath)
        var repository: String?
        var subpath: String?
        switch source {
        case .gitHubRepository(let name, let path, _):
            repository = name
            subpath = path
        case .gitHubRelease(let name, _, _):
            repository = name
        case .localFolder, .agentSkillsDirectory, .curatedRegistry, .bundled:
            break
        }
        return ExtensionInstallPreview(
            name: name,
            kind: kind,
            source: source,
            owner: repository.flatMap(owner(of:)),
            license: license(at: materializedPath),
            lastCommit: lastCommit,
            tracking: tracking,
            subpath: subpath,
            scripts: executables.scripts,
            binaries: executables.binaries,
            requestedPermissions: claims.permissions,
            supportedAgents: claims.agents,
            findings: findings,
            bumblebeeSummary: bumblebeeSummary,
            resolvedCommit: resolvedCommit,
            // Nothing installed yet means every file is new; that is the diff.
            diff: ExtensionAdoptionService.compare(
                external: materializedPath,
                existing: installedPath ?? materializedPath.appendingPathComponent(".none")
            )
        )
    }

    /// Permissions and agents the extension's front matter asks for. Nothing is
    /// granted here; this is only what it says it wants.
    static func manifestClaims(
        at root: URL
    ) -> (permissions: [String], agents: [ExtensionAgentID]) {
        let candidates = ["SKILL.md", "skill.md", "README.md", "uncoil.json"]
        for name in candidates {
            let url = root.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if name.hasSuffix(".json") {
                guard let object = try? JSONSerialization
                    .jsonObject(with: data) as? [String: Any] else { continue }
                let permissions = object["permissions"] as? [String] ?? []
                let agents = (object["agents"] as? [String] ?? [])
                    .compactMap(ExtensionAgentID.init(rawValue:))
                if !permissions.isEmpty || !agents.isEmpty { return (permissions, agents) }
                continue
            }
            let claims = frontMatterClaims(in: text)
            if !claims.permissions.isEmpty || !claims.agents.isEmpty { return claims }
        }
        return ([], [])
    }

    /// Dependencies the extension's own manifest declares. Uncoil does not
    /// install them; it shows what the extension expects to find.
    static func dependencies(at root: URL) -> [String] {
        for name in ["uncoil.json", "package.json", "SKILL.md", "skill.md"] {
            let url = root.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            if name.hasSuffix(".json") {
                guard let object = try? JSONSerialization
                    .jsonObject(with: data) as? [String: Any] else { continue }
                if let list = object["dependencies"] as? [String], !list.isEmpty {
                    return list.sorted()
                }
                if let map = object["dependencies"] as? [String: Any], !map.isEmpty {
                    return map.keys.sorted()
                }
                continue
            }
            let claims = frontMatterList(
                key: "dependencies", in: String(decoding: data, as: UTF8.self)
            )
            if !claims.isEmpty { return claims }
        }
        return []
    }

    /// One list value from YAML front matter, inline or dashed.
    static func frontMatterList(key: String, in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        var values: [String] = []
        var inKey = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if inKey, trimmed.hasPrefix("- ") {
                values.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = String(trimmed[trimmed.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            guard name == key else {
                inKey = false
                continue
            }
            inKey = true
            values.append(contentsOf: String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
        return values
    }

    /// Reads `permissions:` and `agents:` from YAML front matter, as lists on one
    /// line or as dashed items.
    static func frontMatterClaims(
        in text: String
    ) -> (permissions: [String], agents: [ExtensionAgentID]) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([], []) }
        var permissions: [String] = []
        var agentNames: [String] = []
        var current: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("- "), let key = current {
                let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if key == "permissions" { permissions.append(value) } else { agentNames.append(value) }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard key == "permissions" || key == "agents" else {
                current = nil
                continue
            }
            current = key
            let inline = rest
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if key == "permissions" { permissions.append(contentsOf: inline) }
            else { agentNames.append(contentsOf: inline) }
        }
        return (
            permissions,
            agentNames.compactMap(ExtensionAgentID.init(rawValue:))
        )
    }
}

/// The rules an install has to pass. Separate from the machinery that performs
/// it, so each rule is a fact that can be checked on its own.
enum ExtensionInstallGuard {
    enum Blocker: Equatable, Error {
        case referenceNotResolved(String)
        case blockedFinding(String)
        case executablesNotApproved([String])
        case structureInvalid([String])

        var message: String {
            switch self {
            case .referenceNotResolved(let reference):
                "\"\(reference)\" bir sürüm değil; kurulacak commit çözülemedi."
            case .blockedFinding(let message):
                "Güvenlik bulgusu kurulumu engelliyor: \(message)"
            case .executablesNotApproved(let paths):
                "Çalıştırılabilir dosyalar onay bekliyor: "
                    + paths.prefix(3).joined(separator: ", ")
            case .structureInvalid(let issues):
                "Paket yapısı geçersiz: " + issues.prefix(2).joined(separator: ", ")
            }
        }
    }

    /// A moving reference is never stored as a version: `latest` and friends must
    /// be resolved to a commit first, and an unresolved one is a blocker rather
    /// than a value written to disk.
    static let movingReferences = ["latest", "head", "HEAD", "main", "master", "stable", "*"]

    static func isMoving(_ reference: String) -> Bool {
        movingReferences.contains(reference)
            || movingReferences.contains(reference.lowercased())
    }

    /// The version to record. A moving reference is only acceptable when a commit
    /// came with it, and what gets stored is the commit.
    static func recordedVersion(
        requested: String,
        resolvedCommit: String?
    ) -> Result<String, Blocker> {
        if let resolvedCommit, !resolvedCommit.isEmpty {
            return .success(resolvedCommit)
        }
        guard !isMoving(requested), !requested.isEmpty else {
            return .failure(.referenceNotResolved(requested))
        }
        return .success(requested)
    }

    /// Everything standing between the preview and an install.
    static func blockers(
        preview: ExtensionInstallPreview,
        requestedReference: String,
        userApprovedExecutables: Bool,
        structureIssues: [String] = []
    ) -> [Blocker] {
        var blockers: [Blocker] = []
        if case .failure(let blocker) = recordedVersion(
            requested: requestedReference, resolvedCommit: preview.resolvedCommit
        ) {
            blockers.append(blocker)
        }
        for finding in preview.blockingFindings {
            blockers.append(.blockedFinding(finding.message))
        }
        // Uncoil does not run an extension's scripts because it installed it. The
        // user says yes to that, separately and explicitly.
        if !preview.executables.isEmpty, !userApprovedExecutables {
            blockers.append(.executablesNotApproved(preview.executables))
        }
        if !structureIssues.isEmpty {
            blockers.append(.structureInvalid(structureIssues))
        }
        return blockers
    }

    /// Whether the agent configs may be touched. Only a finished install earns
    /// that: a failed one leaves every config exactly as it was.
    static func mayTouchAgentConfig(installSucceeded: Bool) -> Bool {
        installSucceeded
    }
}
