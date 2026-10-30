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
                Spacer(minLength: 28)
            }
            .padding(.leading, SidebarIndent.leading(depth: 0))
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .overlay(alignment: .trailing) {
                Button {
                    collapsed.set(folderID, collapsed: !collapsed.contains(folderID))
                } label: {
                    TablerIcon(name: "chevron-down", size: 12,
                               color: hovering ? Theme.text : Theme.textDim)
                        .rotationEffect(.degrees(collapsed.contains(folderID) ? 0 : 180))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .infoHelp(collapsed.contains(folderID)
                          ? String(localized: "Show projects")
                          : String(localized: "Hide projects"))
                .accessibilityIdentifier("sidebar.folder.toggle.\(folderID.uuidString)")
                .accessibilityValue(collapsed.contains(folderID) ? "collapsed" : "expanded")
                .animation(Theme.Motion.quick, value: collapsed.contains(folderID))
                .padding(.trailing, 4)
            }
            .background(hovering ? Theme.panelHover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .padding(.horizontal, 8)
            .padding(.top, isFirst ? 0 : 6)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar.folder.\(folder.name)")
        }
    }
}
