import SwiftUI

/// What the Extensions window's search bar finds, across every section.
///
/// One list rather than nine: an extension, an agent, a source, a finding and an
/// activity entry can all answer the same question, and each row goes straight to
/// the screen that owns it.
struct ExtensionSearchResults: View {
    @ObservedObject var registry: ExtensionRegistry
    let query: String
    /// Section to show, and the package to expand when there is one.
    let open: (ExtensionsView.Section, String?) -> Void

    private struct Row: Identifiable {
        var id: String
        var icon: String
        var title: String
        var detail: String
        var section: ExtensionsView.Section
        var packageID: String?
        var tint: Color?
    }

    private var matches: [(group: String, rows: [Row])] {
        let value = query.lowercased()
        func hit(_ text: String?) -> Bool {
            guard let text else { return false }
            return text.lowercased().contains(value)
        }

        let skills = registry.packages
            .filter { $0.kind == .skill && (hit($0.name) || hit($0.summary) || hit($0.source.label)) }
            .map { package in
                Row(
                    id: "skill:\(package.id)", icon: "sparkles", title: package.name,
                    detail: package.summary ?? package.source.label,
                    section: .skills, packageID: package.id
                )
            }

        let servers = registry.packages
            .filter { $0.kind == .mcpServer && (hit($0.name) || hit($0.summary) || hit($0.source.label)) }
            .map { package in
                Row(
                    id: "mcp:\(package.id)", icon: "server", title: package.name,
                    detail: package.summary ?? package.source.label,
                    section: .mcpServers, packageID: package.id
                )
            }

        let agents = registry.installations
            .filter { hit($0.agent.displayName) || hit($0.binaryPath) || hit($0.configDirectory) }
            .map { installation in
                Row(
                    id: "agent:\(installation.id)", icon: "robot",
                    title: installation.agent.displayName,
                    detail: installation.binaryPath,
                    section: .agents, packageID: nil
                )
            }

        let sources = registry.effectiveSources
            .filter { $0.lowercased().contains(value) }
            .map { repository in
                Row(
                    id: "source:\(repository)", icon: "brand-github", title: repository,
                    detail: "Kaynak deposu", section: .sources, packageID: nil
                )
            }

        let findings = registry.findings
            .filter { hit($0.rule) || hit($0.message) || hit($0.path) }
            .map { finding in
                Row(
                    id: "finding:\(finding.id)", icon: "shield-lock",
                    title: "\(finding.severity.label) · \(finding.rule)",
                    detail: finding.message,
                    section: .security, packageID: nil,
                    tint: finding.severity >= .high ? Theme.danger : Theme.warn
                )
            }

        let updates = registry.updateCandidates
            .filter { candidate in
                hit(registry.package(id: candidate.extensionID)?.name)
                    || hit(candidate.extensionID)
            }
            .map { candidate in
                Row(
                    id: "update:\(candidate.extensionID)", icon: "refresh",
                    title: registry.package(id: candidate.extensionID)?.name
                        ?? candidate.extensionID,
                    detail: "\(candidate.commitCount) commit · "
                        + candidate.availableCommitSHA.prefix(12),
                    section: .updates, packageID: candidate.extensionID,
                    tint: Theme.highlight
                )
            }

        let events = registry.auditEvents
            .prefix(200)
            .filter { hit($0.detail) || hit($0.kind.label) || hit($0.extensionID) }
            .prefix(15)
            .map { event in
                Row(
                    id: "event:\(event.id.uuidString)", icon: "activity",
                    title: event.kind.label,
                    detail: "\(event.detail) · \(RelativeClock.short(since: event.at))",
                    section: .activity, packageID: nil
                )
            }

        return [
            ("Skill", skills),
            ("MCP server", servers),
            ("Agent", agents),
            ("Kaynak", sources),
            ("Güvenlik bulgusu", findings),
            ("Güncelleme", updates),
            ("Etkinlik", Array(events)),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        let groups = matches
        VStack(alignment: .leading, spacing: 18) {
            if groups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sonuç yok")
                        .font(Theme.mono(12, .semibold))
                        .foregroundStyle(Theme.text)
                    Text("\"\(query)\" hiçbir extension, agent, kaynak, bulgu veya kayıtla eşleşmedi.")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .panel()
            }

            ForEach(groups, id: \.group) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(group.group)
                            .font(Theme.mono(12, .semibold))
                            .foregroundStyle(Theme.text)
                        Text("\(group.rows.count)")
                            .font(Theme.mono(9.5, .semibold))
                            .foregroundStyle(Theme.textFaint)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            Button {
                                open(row.section, row.packageID)
                            } label: {
                                HStack(spacing: 9) {
                                    TablerIcon(
                                        name: row.icon, size: 13, color: row.tint ?? Theme.textDim
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.title)
                                            .font(Theme.mono(11.5, .medium))
                                            .foregroundStyle(row.tint ?? Theme.text)
                                        Text(row.detail)
                                            .font(Theme.mono(10))
                                            .foregroundStyle(Theme.textFaint)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(row.section.title)
                                        .font(Theme.mono(9.5))
                                        .foregroundStyle(Theme.textFaint)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(Theme.textFaint)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("extensions.search.result.\(row.id)")
                            if index != group.rows.count - 1 {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                    .panel()
                }
            }
        }
        .accessibilityIdentifier("extensions.search.results")
    }
}
