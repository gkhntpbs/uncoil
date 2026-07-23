import SwiftUI

/// Uncoil's own folder picker — no stock NSOpenPanel.
struct FolderPickerSheet: View {
    var onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var currentURL = FileManager.default.homeDirectoryForCurrentUser
    @State private var entries: [URL] = []

    private var shortcuts: [(String, URL)] {
        var items: [(String, URL)] = [
            ("Ev", FileManager.default.homeDirectoryForCurrentUser),
            ("Masaüstü", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")),
            ("Belgeler", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")),
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in volumes where volume.path != "/" {
            items.append((volume.lastPathComponent, volume))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: breadcrumb path
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.claude)
                Text(displayPath)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button {
                    currentURL = currentURL.deletingLastPathComponent()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .disabled(currentURL.path == "/")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Theme.border)

            HStack(spacing: 0) {
                // Shortcuts rail
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shortcuts, id: \.1) { name, url in
                        Button {
                            currentURL = url
                        } label: {
                            Text(name)
                                .font(Theme.mono(11))
                                .foregroundStyle(
                                    currentURL.path.hasPrefix(url.path) ? Theme.text : Theme.textDim
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    currentURL == url ? Theme.panelActive : .clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(8)
                .frame(width: 150)

                Divider().overlay(Theme.border)

                // Directory list
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(entries, id: \.self) { url in
                            DirectoryRow(url: url) {
                                currentURL = url
                            }
                        }
                        if entries.isEmpty {
                            Text("Alt klasör yok")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textFaint)
                                .padding(.top, 24)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(minHeight: 300)

            Divider().overlay(Theme.border)

            // Footer
            HStack {
                Button("Vazgeç") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Bu Klasörü Ekle") {
                    onPick(currentURL)
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
            }
            .padding(12)
        }
        .frame(width: 560, height: 430)
        .background(Theme.bg)
        .task(id: currentURL) { refresh() }
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if currentURL.path.hasPrefix(home) {
            return "~" + currentURL.path.dropFirst(home.count)
        }
        return currentURL.path
    }

    private func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: currentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        entries = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}

private struct DirectoryRow: View {
    let url: URL
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                Text(url.lastPathComponent)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Button styles

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Theme.claude.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 7)
            )
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(12))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                configuration.isPressed ? Theme.panelActive : Theme.panel,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}
