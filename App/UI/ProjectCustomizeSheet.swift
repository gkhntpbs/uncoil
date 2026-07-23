import SwiftUI

/// Customize a project's identity: name, icon (Tabler), and accent color.
struct ProjectCustomizeSheet: View {
    let project: Project
    @EnvironmentObject private var projectStore: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedIcon: String?
    @State private var selectedColor: UInt32?
    @State private var search = ""

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 10)

    private var filteredIcons: [String] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            return Array(TablerIcons.sortedNames.prefix(300))
        }
        return TablerIcons.sortedNames.filter { $0.contains(query) }.prefix(300).map { $0 }
    }

    private var previewColor: Color {
        selectedColor.map { Color(hex: $0) } ?? Theme.textDim
    }

    var body: some View {
        VStack(spacing: 0) {
            // Live preview row
            HStack(spacing: 10) {
                if let icon = selectedIcon {
                    TablerIcon(name: icon, size: 16, color: previewColor)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(previewColor)
                }
                Text(name.isEmpty ? project.name : name)
                    .font(Theme.mono(13, .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("önizleme")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(12)
            .background(Theme.panel)

            Divider().overlay(Theme.border)

            VStack(alignment: .leading, spacing: 12) {
                // Name
                TextField("Proje adı", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )

                // Colors
                HStack(spacing: 8) {
                    ForEach(ProjectPalette.colors, id: \.self) { hex in
                        Button {
                            selectedColor = selectedColor == hex ? nil : hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            selectedColor == hex ? Theme.text : .clear,
                                            lineWidth: 2
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if selectedIcon != nil || selectedColor != nil {
                        Button("Sıfırla") {
                            selectedIcon = nil
                            selectedColor = nil
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }

                // Icon search
                TextField("İkon ara (tabler icons — \(TablerIcons.map.count) ikon)", text: $search)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )

                // Icon grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(filteredIcons, id: \.self) { iconName in
                            Button {
                                selectedIcon = selectedIcon == iconName ? nil : iconName
                            } label: {
                                TablerIcon(
                                    name: iconName,
                                    size: 15,
                                    color: selectedIcon == iconName ? previewColor : Theme.textDim
                                )
                                .frame(width: 32, height: 30)
                                .background(
                                    selectedIcon == iconName ? Theme.panelActive : Theme.panel,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(
                                            selectedIcon == iconName ? previewColor.opacity(0.6) : .clear,
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .help(iconName)
                        }
                    }
                    .padding(2)
                    .uncoilScrollers()
                }
                .frame(height: 190)
            }
            .padding(14)

            Divider().overlay(Theme.border)

            HStack {
                Button("Vazgeç") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Kaydet") {
                    projectStore.updateProject(project.id) { p in
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { p.name = trimmed }
                        p.iconName = selectedIcon
                        p.colorHex = selectedColor
                    }
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
            }
            .padding(12)
        }
        .frame(width: 460)
        .background(Theme.bg)
        .onAppear {
            name = project.name
            selectedIcon = project.iconName
            selectedColor = project.colorHex
        }
    }
}

/// Shared project icon: custom Tabler icon + color, or the default folder.
struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 12

    var body: some View {
        if let iconName = project.iconName {
            TablerIcon(name: iconName, size: size + 2, color: project.accentColor)
        } else {
            Image(systemName: "folder.fill")
                .font(.system(size: size - 1))
                .foregroundStyle(project.colorHex != nil ? project.accentColor : Theme.textDim)
        }
    }
}
