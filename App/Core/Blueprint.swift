import Foundation

/// A named prompt that sets a project up the way you always set projects up.
///
/// People build the same shapes over and over — a workspace with `api/`, `web/`
/// and `docs/` under it, the same three markdown files at the root, the same
/// opening instructions to an agent — and retype the same paragraph every time.
/// A blueprint is that paragraph, kept.
///
/// **Uncoil creates nothing on disk.** The blueprint is handed to an agent and
/// the agent does the work, which is the whole point: the judgement about what
/// `CLAUDE.md` should say for *this* project is exactly what an agent is for,
/// and a directory tree Uncoil stamped out would still need that judgement
/// applied on top.
struct Blueprint: Identifiable, Equatable {
    /// Folder-safe slug; also the file name and the id agents address it by.
    let id: String
    var name: String
    /// Tabler icon name; nil = the default mark.
    var iconName: String?
    /// Accent as 0xRRGGBB; nil = neutral.
    var colorHex: UInt32?
    var prompt: String
    /// Whether the prompt is sent the moment the session opens, or typed in and
    /// left for the user to read and send.
    var startsImmediately: Bool
    /// An agent wrote this and nobody has opened it since.
    ///
    /// Blueprints are text that later gets fed to an agent, so one written by
    /// an agent is treated as a draft until a human has looked at it — see
    /// `BlueprintStore.save(_:writtenByAgent:)`.
    var needsReview: Bool

    init(
        id: String,
        name: String,
        iconName: String? = nil,
        colorHex: UInt32? = nil,
        prompt: String,
        startsImmediately: Bool = false,
        needsReview: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.prompt = prompt
        self.startsImmediately = startsImmediately
        self.needsReview = needsReview
    }

    // MARK: - Placeholders

    static let projectNamePlaceholder = "{{project_name}}"
    static let projectPathPlaceholder = "{{project_path}}"

    /// The prompt as the agent will receive it.
    ///
    /// Only two placeholders, and both are facts about the project rather than
    /// anything the user has to remember to define. A blueprint that wants more
    /// can simply say it in prose — it is talking to an agent, not to a
    /// template engine.
    func resolvedPrompt(for project: Project) -> String {
        prompt
            .replacingOccurrences(of: Self.projectNamePlaceholder, with: project.name)
            .replacingOccurrences(of: Self.projectPathPlaceholder, with: project.rootPath)
    }

    /// The shape agents see over the control plane. Field names stay English
    /// and snake_case like the rest of the protocol surface — agents parse it.
    func asJSON() -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "icon": .string(optional: iconName),
            "prompt": .string(prompt),
            "starts_immediately": .bool(startsImmediately),
            "needs_review": .bool(needsReview),
        ])
    }

    // MARK: - File format

    /// Markdown with YAML front matter, the same shape as `SKILL.md`.
    ///
    /// Not JSON, and not for consistency's sake: the body is a long prompt, and
    /// a long prompt inside a JSON string is a wall of `\n` escapes that nobody
    /// can read or hand-edit. In this shape exporting a blueprint is copying a
    /// file, importing one is putting a file back, and an agent asked to write
    /// one is writing the format it already writes every day.
    func markdown() -> String {
        var lines = ["---", "name: \(name)"]
        if let iconName { lines.append("icon: \(iconName)") }
        if let colorHex { lines.append(String(format: "color: %06X", colorHex)) }
        lines.append("startsImmediately: \(startsImmediately)")
        if needsReview { lines.append("needsReview: true") }
        lines.append("---")
        lines.append("")
        lines.append(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Reads one back. Returns nil rather than throwing for a file that is not
    /// a blueprint at all — a stray file in the folder must not take the whole
    /// list down with it.
    static func parse(_ text: String, id: String) -> Blueprint? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        var bodyStart: Int?
        for (offset, line) in lines.dropFirst().enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                bodyStart = offset + 2
                break
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            fields[key] = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        guard let bodyStart, let name = fields["name"], !name.isEmpty else { return nil }
        let body = lines.dropFirst(bodyStart)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Blueprint(
            id: id,
            name: name,
            iconName: fields["icon"].flatMap { $0.isEmpty ? nil : $0 },
            colorHex: fields["color"].flatMap {
                UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16)
            },
            prompt: body,
            startsImmediately: fields["startsImmediately"] == "true",
            needsReview: fields["needsReview"] == "true"
        )
    }
}
