import Foundation

extension CapabilityRouter {
    func handleSessionGroups(
        _ request: ControlRequest,
        caller: SessionRecord,
        grants: Set<String>
    ) -> ControlEnvelope? {
        let actions = Set([
            "list_groups", "create_group", "rename_group",
            "assign_group", "delete_group",
        ])
        guard actions.contains(request.action) else { return nil }

        let projectID: UUID
        if let raw = request.args["project_id"]?.stringValue,
           let requested = UUID(uuidString: raw) {
            guard requested == caller.projectID || grants.contains("sessions.cross_project") else {
                return .failure(request, code: .permissionDenied,
                    message: "cross-project group access requires sessions.cross_project")
            }
            projectID = requested
        } else {
            projectID = caller.projectID
        }

        switch request.action {
        case "list_groups":
            let groups = projectStore.groups(for: projectID).map { group in
                JSONValue.object([
                    "id": .string(group.id.uuidString),
                    "name": .string(group.name),
                    "project_id": .string(group.projectID.uuidString),
                    "session_ids": .array(
                        projectStore.sessions(in: group.id).map {
                            .string($0.id.uuidString)
                        }
                    ),
                ])
            }
            let ungrouped = projectStore.sessions(for: projectID)
                .filter { $0.groupID == nil }
                .map { JSONValue.string($0.id.uuidString) }
            return .success(request, data: .object([
                "groups": .array(groups),
                "ungrouped_session_ids": .array(ungrouped),
            ]), project_id: projectID.uuidString)

        case "create_group":
            guard grants.contains("sessions.organize") else {
                return .failure(request, code: .capabilityDisabled,
                    message: "sessions.organize is not granted")
            }
            guard let name = request.args["name"]?.stringValue,
                  let group = projectStore.createGroup(projectID: projectID, name: name) else {
                return .failure(request, code: .invalidArgument,
                    message: "'name' is required and must not be empty")
            }
            return .success(request, data: .object([
                "group_id": .string(group.id.uuidString),
                "name": .string(group.name),
            ]), project_id: projectID.uuidString)

        case "rename_group":
            guard grants.contains("sessions.organize") else {
                return .failure(request, code: .capabilityDisabled,
                    message: "sessions.organize is not granted")
            }
            guard let group = resolveGroup(request, projectID: projectID),
                  let name = request.args["name"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return .failure(request, code: .invalidArgument,
                    message: "'group_id' and non-empty 'name' are required")
            }
            projectStore.updateGroup(group.id) { $0.name = name }
            return .success(request, data: .object([
                "group_id": .string(group.id.uuidString),
                "name": .string(name),
            ]), project_id: projectID.uuidString)

        case "assign_group":
            guard grants.contains("sessions.organize") else {
                return .failure(request, code: .capabilityDisabled,
                    message: "sessions.organize is not granted")
            }
            let groupID: UUID?
            if let raw = request.args["group_id"]?.stringValue {
                guard let parsed = UUID(uuidString: raw),
                      projectStore.sessionGroups.contains(where: {
                          $0.id == parsed && $0.projectID == projectID
                      }) else {
                    return .failure(request, code: .invalidArgument,
                        message: "'group_id' must identify a group in the project")
                }
                groupID = parsed
            } else {
                groupID = nil
            }
            guard let values = request.args["session_ids"]?.arrayValue else {
                return .failure(request, code: .invalidArgument,
                    message: "'session_ids' is required")
            }
            let ids = Set(values.compactMap { value in
                value.stringValue.flatMap(UUID.init(uuidString:))
            })
            guard !ids.isEmpty,
                  ids.allSatisfy({ id in
                      projectStore.sessions.contains {
                          $0.id == id && $0.projectID == projectID
                      }
                  }) else {
                return .failure(request, code: .invalidArgument,
                    message: "every session_id must identify a session in the project")
            }
            projectStore.assignSessions(ids, to: groupID)
            return .success(request, data: .object([
                "assigned": .int(ids.count),
                "group_id": .string(optional: groupID?.uuidString),
            ]), project_id: projectID.uuidString)

        case "delete_group":
            guard grants.contains("sessions.organize") else {
                return .failure(request, code: .capabilityDisabled,
                    message: "sessions.organize is not granted")
            }
            guard let group = resolveGroup(request, projectID: projectID) else {
                return .failure(request, code: .invalidArgument,
                    message: "'group_id' must identify a group in the project")
            }
            projectStore.removeGroup(group.id)
            return .success(request, data: .object([
                "deleted": .bool(true),
                "group_id": .string(group.id.uuidString),
            ]), project_id: projectID.uuidString)

        default:
            return nil
        }
    }

    private func resolveGroup(
        _ request: ControlRequest,
        projectID: UUID
    ) -> SessionGroup? {
        guard let raw = request.args["group_id"]?.stringValue,
              let id = UUID(uuidString: raw) else { return nil }
        return projectStore.sessionGroups.first {
            $0.id == id && $0.projectID == projectID
        }
    }
}
