import Foundation

extension CapabilityRouter {
    private static let maxArtifactBytes = 256 * 1024

    func handleArtifacts(_ request: ControlRequest) -> ControlEnvelope {
        guard let caller = caller(of: request) else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        let grants = PolicyEngine.grants(for: caller)

        switch request.action {
        case "list":
            guard let target = artifactTarget(request, caller: caller, grants: grants) else {
                return .failure(request, code: .permissionDenied, message: "artifact root not accessible")
            }
            let root = target.artifactRoot(dataDirectory: dataDirectory)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            let list = files.filter { !$0.hasDirectoryPath }.map { url -> JSONValue in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return .object(["name": .string(url.lastPathComponent), "size": .int(size)])
            }
            return .success(request, data: .object(["artifacts": .array(list)]),
                            target_session_id: target.id.uuidString)

        case "inspect", "read_text", "resolve_path":
            guard let target = artifactTarget(request, caller: caller, grants: grants) else {
                return .failure(request, code: .permissionDenied, message: "artifact root not accessible")
            }
            guard let name = request.args["name"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'name' is required")
            }
            let root = target.artifactRoot(dataDirectory: dataDirectory)
            guard let resolved = Self.containedPath(root: root, name: name) else {
                return .failure(request, code: .invalidPath,
                    message: "path escapes the artifact root", target_session_id: target.id.uuidString)
            }
            if request.action == "resolve_path" {
                return .success(request, data: .object(["path": .string(resolved)]),
                                target_session_id: target.id.uuidString)
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
                return .failure(request, code: .invalidPath, message: "no such artifact",
                                target_session_id: target.id.uuidString)
            }
            let attrs = (try? FileManager.default.attributesOfItem(atPath: resolved)) ?? [:]
            let size = (attrs[.size] as? Int) ?? 0
            if request.action == "inspect" {
                let modified = (attrs[.modificationDate] as? Date).map { ISO8601DateFormatter().string(from: $0) }
                return .success(request, data: .object([
                    "name": .string(name),
                    "path": .string(resolved),
                    "size": .int(size),
                    "modified_at": .string(optional: modified),
                ]), target_session_id: target.id.uuidString)
            }
            // read_text
            guard size <= Self.maxArtifactBytes else {
                return .failure(request, code: .invalidArgument,
                    message: "artifact exceeds 256 KB", target_session_id: target.id.uuidString)
            }
            guard let data = FileManager.default.contents(atPath: resolved) else {
                return .failure(request, code: .invalidPath, message: "unreadable artifact",
                                target_session_id: target.id.uuidString)
            }
            return .success(request, data: .object([
                "name": .string(name),
                "text": .string(String(decoding: data, as: UTF8.self)),
                "bytes": .int(data.count),
            ]), target_session_id: target.id.uuidString)

        case "register":
            guard grants.contains("artifacts.write") else {
                return .failure(request, code: .capabilityDisabled, message: "artifacts.write is not granted")
            }
            guard let name = request.args["name"]?.stringValue, !name.isEmpty else {
                return .failure(request, code: .invalidArgument, message: "'name' is required")
            }
            let root = caller.artifactRoot(dataDirectory: dataDirectory)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let metaURL = root.appendingPathComponent("artifacts.json")
            var entries: [JSONValue] = []
            if let data = try? Data(contentsOf: metaURL),
               let existing = try? JSONDecoder().decode([JSONValue].self, from: data) {
                entries = existing
            }
            entries.append(.object([
                "name": .string(name),
                "kind": .string(optional: request.args["kind"]?.stringValue),
                "description": .string(optional: request.args["description"]?.stringValue),
                "registered_at": .string(ISO8601DateFormatter().string(from: Date())),
            ]))
            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: metaURL, options: .atomic)
            }
            return .success(request, data: .object(["registered": .string(name), "count": .int(entries.count)]),
                            target_session_id: caller.id.uuidString)

        default:
            return .failure(request, code: .invalidAction, message: "unsupported artifact action")
        }
    }

    /// Appends artifact metadata to the caller's `artifacts.json`. Shared by
    /// the browser/computer handlers so their screenshots/state files show up
    /// in `uncoil_artifacts list` exactly like `register` entries.
    func recordArtifact(name: String, kind: String?, description: String?, caller: SessionRecord) {
        let root = caller.artifactRoot(dataDirectory: dataDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metaURL = root.appendingPathComponent("artifacts.json")
        var entries: [JSONValue] = []
        if let data = try? Data(contentsOf: metaURL),
           let existing = try? JSONDecoder().decode([JSONValue].self, from: data) {
            entries = existing
        }
        entries.append(.object([
            "name": .string(name),
            "kind": .string(optional: kind),
            "description": .string(optional: description),
            "registered_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]))
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    // MARK: - Helpers

    /// The session whose artifact root the request targets, or nil if the
    /// caller may not access it. Own root is always allowed; a same-project
    /// session's root needs the `artifacts.read` grant.
    func artifactTarget(_ request: ControlRequest, caller: SessionRecord, grants: Set<String>) -> SessionRecord? {
        guard let raw = request.args["session_id"]?.stringValue else { return caller }
        guard let target = session(id: raw) else { return nil }
        if target.id == caller.id { return target }
        if target.projectID == caller.projectID && grants.contains("artifacts.read") { return target }
        return nil
    }

    /// Resolves `name` under `root`, rejecting symlink escapes. Returns the
    /// canonical absolute path, or nil if it would fall outside `root`.
    /// Static & pure for direct unit testing.
    nonisolated static func containedPath(root: URL, name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("..") else { return nil }
        // The root must exist so we have a canonical anchor to compare against.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let rootReal = realpathString(root.path) else { return nil }
        let candidate = root.appendingPathComponent(name).standardizedFileURL
        let candidateReal: String
        if let real = realpathString(candidate.path) {
            candidateReal = real
        } else {
            // Nonexistent leaf: resolve the parent (catches symlinked parents).
            let parent = candidate.deletingLastPathComponent()
            guard let parentReal = realpathString(parent.path) else { return nil }
            candidateReal = parentReal + "/" + candidate.lastPathComponent
        }
        guard candidateReal == rootReal || candidateReal.hasPrefix(rootReal + "/") else { return nil }
        return candidateReal
    }

    nonisolated static func realpathString(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }
}
