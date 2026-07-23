import Foundation

extension CapabilityRouter {
    /// Effective grants for the request's caller (default grant set when the
    /// caller session can't be resolved — the socket is already euid-gated).
    func grants(for request: ControlRequest) -> Set<String> {
        if let caller = caller(of: request) { return PolicyEngine.grants(for: caller) }
        return PolicyEngine.defaultGrants
    }

    func handleProjects(_ request: ControlRequest) -> ControlEnvelope {
        switch request.action {
        case "current":
            guard let caller = caller(of: request) else {
                return .failure(request, code: .unknownSession, message: "caller session not found")
            }
            guard let project = project(id: caller.projectID) else {
                return .failure(request, code: .unknownProject, message: "caller project not found")
            }
            return .success(request, data: projectData(project), project_id: project.id.uuidString)

        case "list":
            let list = projectStore.projects.map { project -> JSONValue in
                .object([
                    "id": .string(project.id.uuidString),
                    "name": .string(project.name),
                    "root_path": .string(project.rootPath),
                ])
            }
            return .success(request, data: .object(["projects": .array(list)]))

        case "inspect":
            guard let project = resolveProject(request) else {
                return .failure(request, code: .unknownProject, message: "project not found")
            }
            return .success(request, data: projectData(project), project_id: project.id.uuidString)

        case "list_worktrees":
            guard let project = resolveProject(request) else {
                return .failure(request, code: .unknownProject, message: "project not found")
            }
            return .success(request, data: .object(["worktrees": worktreesJSON(project.rootPath)]),
                            project_id: project.id.uuidString)

        case "create_worktree":
            guard grants(for: request).contains("worktrees.create") else {
                return .failure(request, code: .capabilityDisabled, message: "worktrees.create is not granted")
            }
            guard let project = resolveProject(request) else {
                return .failure(request, code: .unknownProject, message: "project not found")
            }
            guard let name = request.args["name"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'name' is required")
            }
            guard Self.isValidWorktreeName(name) else {
                return .failure(request, code: .invalidArgument,
                    message: "name must match [a-zA-Z0-9._-]{1,64}")
            }
            switch GitService.createWorktree(repoPath: project.rootPath, name: name) {
            case .success(let worktree):
                return .success(request, data: .object([
                    "path": .string(worktree.path),
                    "branch": .string(optional: worktree.branch),
                    "is_main": .bool(worktree.isMain),
                ]), project_id: project.id.uuidString)
            case .failure(let failure):
                return .failure(request, code: .invalidPath, message: failure.message)
            }

        case "list_presets":
            return .success(request, data: .object(["presets": .array([])]),
                            warnings: ["presets not yet configured"])

        default:
            return .failure(request, code: .invalidAction, message: "unsupported project action")
        }
    }

    // MARK: - Helpers

    /// Resolves the target project: explicit `project_id` arg, else the
    /// caller's project.
    func resolveProject(_ request: ControlRequest) -> Project? {
        if let raw = request.args["project_id"]?.stringValue {
            guard let id = UUID(uuidString: raw) else { return nil }
            return project(id: id)
        }
        if let caller = caller(of: request) { return project(id: caller.projectID) }
        return nil
    }

    nonisolated static func isValidWorktreeName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }

    func worktreesJSON(_ repoPath: String) -> JSONValue {
        .array(GitService.worktrees(repoPath: repoPath).map { worktree in
            .object([
                "path": .string(worktree.path),
                "branch": .string(optional: worktree.branch),
                "is_main": .bool(worktree.isMain),
            ])
        })
    }

    func projectData(_ project: Project) -> JSONValue {
        let snapshot = GitService.snapshot(repoPath: project.rootPath)
        let gitFile = URL(fileURLWithPath: project.rootPath).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        let gitExists = FileManager.default.fileExists(atPath: gitFile.path, isDirectory: &isDir)
        // A linked worktree has a `.git` FILE (gitdir pointer), not a directory.
        let isWorktree = gitExists && !isDir.boolValue
        let sessionIDs = projectStore.sessions(for: project.id).map { JSONValue.string($0.id.uuidString) }
        return .object([
            "id": .string(project.id.uuidString),
            "name": .string(project.name),
            "root_path": .string(project.rootPath),
            "repository": .object([
                "is_repo": .bool(snapshot.isRepo),
                "branch": .string(optional: snapshot.branch),
                "is_worktree": .bool(isWorktree),
            ]),
            "worktrees": worktreesJSON(project.rootPath),
            "session_ids": .array(sessionIDs),
        ])
    }
}
