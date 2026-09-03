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
            let presets = (settings?.presets ?? SessionPreset.builtInDefaults).map { $0.asJSON() }
            return .success(request, data: .object(["presets": .array(presets)]))

        case "inspect_preset":
            guard let id = request.args["preset_id"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'preset_id' is required")
            }
            let presets = settings?.presets ?? SessionPreset.builtInDefaults
            guard let preset = presets.first(where: { $0.id == id }) else {
                return .failure(request, code: .invalidArgument, message: "unknown preset_id '\(id)'")
            }
            return .success(request, data: preset.asJSON())

        case "list_blueprints":
            let list = blueprints.blueprints.map { $0.asJSON() }
            return .success(request, data: .object(["blueprints": .array(list)]))

        case "inspect_blueprint":
            guard let id = request.args["blueprint_id"]?.stringValue else {
                return .failure(request, code: .invalidArgument, message: "'blueprint_id' is required")
            }
            guard let blueprint = blueprints.blueprint(id: id) else {
                return .failure(request, code: .invalidArgument, message: "unknown blueprint_id '\(id)'")
            }
            return .success(request, data: blueprint.asJSON())

        case "save_blueprint":
            return requiringBlueprintWrite(request) { saveBlueprint(request) }

        case "delete_blueprint":
            return requiringBlueprintWrite(request) {
                guard let id = request.args["blueprint_id"]?.stringValue else {
                    return .failure(request, code: .invalidArgument,
                        message: "'blueprint_id' is required")
                }
                do {
                    try blueprints.delete(id: id)
                    return .success(request, data: .object(["deleted": .string(id)]))
                } catch {
                    return .failure(request, code: .invalidArgument,
                        message: error.localizedDescription)
                }
            }

        default:
            return .failure(request, code: .invalidAction, message: "unsupported project action")
        }
    }

    // MARK: - Blueprints

    /// Blueprint writes are attributed, not merely granted.
    ///
    /// `grants(for:)` falls back to the default set when the caller cannot be
    /// resolved, which is right for reads on a socket that is already
    /// euid-gated. It is wrong here: a blueprint is text that later gets fed to
    /// an agent, so writing one has to be traceable to a session the user
    /// opened for it — `uncoil_tasks` refuses an unresolvable caller for the
    /// same reason.
    private func requiringBlueprintWrite(
        _ request: ControlRequest,
        _ body: () -> ControlEnvelope
    ) -> ControlEnvelope {
        guard let caller = caller(of: request) else {
            return .failure(request, code: .unknownSession, message: "caller session not found")
        }
        guard PolicyEngine.grants(for: caller).contains("blueprints.write") else {
            return .failure(request, code: .capabilityDisabled,
                message: "blueprints.write is not granted")
        }
        return body()
    }

    private func saveBlueprint(_ request: ControlRequest) -> ControlEnvelope {
        guard let name = request.args["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return .failure(request, code: .invalidArgument,
                message: "'name' is required and must not be empty")
        }
        guard name.count <= 60 else {
            return .failure(request, code: .invalidArgument, message: "'name' exceeds 60 characters")
        }
        guard let rawPrompt = request.args["prompt"]?.stringValue, !rawPrompt.isEmpty else {
            return .failure(request, code: .invalidArgument,
                message: "'prompt' is required and must not be empty")
        }
        guard rawPrompt.count <= BlueprintStore.promptLimit else {
            return .failure(request, code: .invalidArgument,
                message: "prompt exceeds \(BlueprintStore.promptLimit) characters")
        }
        // The same escape defence the child launcher applies: this text ends up
        // in a PTY, just later than usual.
        let prompt = Self.sanitizePrompt(rawPrompt)
        guard !prompt.isEmpty else {
            return .failure(request, code: .invalidArgument,
                message: "'prompt' is empty after removing control characters")
        }

        // An explicit id updates that blueprint; without one a fresh slug is
        // taken, so writing "Full stack" twice never silently replaces the
        // user's own copy.
        let requestedID = request.args["blueprint_id"]?.stringValue
        let id = requestedID ?? blueprints.availableID(for: name)
        guard !id.isEmpty else {
            return .failure(request, code: .invalidArgument,
                message: "'name' must contain a letter or a digit")
        }

        do {
            let saved = try blueprints.save(
                Blueprint(
                    id: id,
                    name: name,
                    iconName: request.args["icon"]?.stringValue,
                    prompt: prompt
                ),
                writtenByAgent: true
            )
            return .success(request, data: saved.asJSON(), warnings: [
                "Stored as a draft: it will not start a session on its own until the user opens it.",
            ])
        } catch {
            return .failure(request, code: .ioError, message: error.localizedDescription)
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
