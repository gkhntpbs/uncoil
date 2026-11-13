import SwiftUI

struct ProjectFolderSheet: View {
    let folder: ProjectFolder
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon: String?
    @State private var color: UInt32?

    var body: some View {
        SheetScaffold(title: String(localized: "Project Folder"),
                      subtitle: String(localized: "Organize projects without moving their files or changing their settings."),
                      width: 480) {
            VStack(spacing: Theme.Space.snug) {
                SheetField(label: String(localized: "Name")) {
                    SheetTextField(placeholder: String(localized: "Folder name"), text: $name)
                }
                IconColorPicker(iconName: $icon, colorHex: $color)
            }
            .padding(Theme.Space.section)
        } actions: {
            Button(String(localized: "Cancel")) { dismiss() }.buttonStyle(GhostButtonStyle())
            Spacer()
            Button(String(localized: "Save")) {
                var updated = folder
                updated.name = name
                updated.iconName = icon
                updated.colorHex = color
                store.saveProjectFolder(updated)
                dismiss()
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear {
            name = folder.name
            icon = folder.iconName
            color = folder.colorHex
        }
    }
}

struct ProjectFolderRow: View {
    let folderID: UUID
    let isFirst: Bool
    /// How many folders this one sits inside.
    var depth: Int = 0
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject private var collapsed = CollapsedProjects.shared
    @State private var hovering = false

    var body: some View {
        if let folder = store.projectFolders.first(where: { $0.id == folderID }) {
            HStack(spacing: 8) {
                if let icon = folder.iconName {
                    TablerIcon(name: icon, size: 14,
                               color: folder.colorHex.map { Color(hex: $0) } ?? Theme.textDim)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(folder.colorHex.map { Color(hex: $0) } ?? Theme.textDim)
                }
                Text(folder.name)
                    .font(Theme.mono(.large, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .infoHelp(folder.name)
                Spacer(minLength: 4)
                SidebarRunIndicator(projectIDs: store.projectIDs(inFolder: folderID))
                Spacer().frame(width: 24)
            }
            .padding(.leading, SidebarIndent.leading(depth: 0) + CGFloat(depth) * 12)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .overlay(alignment: .trailing) {
                TablerIcon(name: "chevron-down", size: 12,
                           color: hovering ? Theme.text : Theme.textDim)
                    .rotationEffect(.degrees(collapsed.contains(folderID) ? 0 : 180))
                    .frame(width: 20, height: 20)
                    .animation(Theme.Motion.quick, value: collapsed.contains(folderID))
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            }
            .background(hovering ? Theme.panelHover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .padding(.horizontal, 8)
            .padding(.top, isFirst ? 0 : 6)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar.folder.\(folder.name)")
            .accessibilityValue(collapsed.contains(folderID) ? "collapsed" : "expanded")

        }
    }
}

/// A small "something is running here" mark for sidebar rows: a project's own
/// dev servers, or — on a folder — those of every project inside it, however
/// deep. A run is otherwise only visible on the project's Run tab, so a server
/// left up in a folded folder was easy to forget.
struct SidebarRunIndicator: View {
    let projectIDs: [UUID]
    @ObservedObject private var runs = RunRegistry.shared

    private struct Summary {
        var running = 0
        var starting = 0
        var failed = 0
        var names: [String] = []
        var isEmpty: Bool { running + starting + failed == 0 }
    }

    private var summary: Summary {
        let ids = Set(projectIDs)
        var summary = Summary()
        for (key, state) in runs.states where ids.contains(key.projectID) {
            switch state.status {
            case .running:
                summary.running += 1
                summary.names.append(key.configID)
            case .starting:
                summary.starting += 1
                summary.names.append(key.configID)
            case .failed:
                summary.failed += 1
            case .idle, .exited:
                break
            }
        }
        return summary
    }

    var body: some View {
        let summary = summary
        if !summary.isEmpty {
            let color = summary.failed > 0 && summary.running + summary.starting == 0
                ? Theme.danger
                : (summary.starting > 0 && summary.running == 0 ? Theme.warn : Theme.ok)
            let active = summary.running + summary.starting
            HStack(spacing: 3) {
                TablerIcon(name: summary.failed > 0 && active == 0 ? "alert-triangle" : "player-play",
                           size: 9, color: color)
                if active > 1 {
                    Text("\(active)")
                        .font(Theme.mono(.micro, .medium))
                        .foregroundStyle(color)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .help(help(summary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help(summary))
            .accessibilityIdentifier("sidebar.runIndicator")
        }
    }

    private func help(_ summary: Summary) -> String {
        var parts: [String] = []
        if summary.running > 0 { parts.append(String(localized: "\(summary.running) running")) }
        if summary.starting > 0 { parts.append(String(localized: "\(summary.starting) starting")) }
        if summary.failed > 0 { parts.append(String(localized: "\(summary.failed) failed")) }
        let names = summary.names.sorted().joined(separator: ", ")
        return parts.joined(separator: " · ") + (names.isEmpty ? "" : " — \(names)")
    }
}
