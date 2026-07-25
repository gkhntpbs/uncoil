import AppKit
import SwiftUI

struct ExtensionsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview
        case agents
        case skills
        case mcpServers
        case assignments
        case sources
        case security
        case updates
        case activity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .agents: "Agents"
            case .skills: "Skills"
            case .mcpServers: "MCP Servers"
            case .assignments: "Assignments"
            case .sources: "Sources"
            case .security: "Security"
            case .updates: "Updates"
            case .activity: "Activity"
            }
        }

        var iconName: String {
            switch self {
            case .overview: "layout-dashboard"
            case .agents: "robot"
            case .skills: "sparkles"
            case .mcpServers: "server"
            case .assignments: "arrows-exchange"
            case .sources: "database"
            case .security: "shield-lock"
            case .updates: "refresh"
            case .activity: "activity"
            }
        }

        var description: String {
            switch self {
            case .overview: "Agent extension sisteminin genel durumu"
            case .agents: "Kurulu agent’lar ve profilleri"
            case .skills: "Kullanılabilir skill paketleri"
            case .mcpServers: "MCP server tanımları ve durumları"
            case .assignments: "Agent ve proje atamaları"
            case .sources: "Extension kaynakları"
            case .security: "Güven ve izin politikaları"
            case .updates: "Paket güncellemeleri"
            case .activity: "Extension etkinlik geçmişi"
            }
        }
    }

    @State private var selection: Section = .overview

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
            content
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .background(ExtensionsWindowFrame())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensions.container")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
                .frame(height: 42)
            Text("EXTENSIONS")
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ForEach(Section.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 9) {
                        TablerIcon(
                            name: section.iconName,
                            size: 13,
                            color: selection == section ? Theme.text : Theme.textDim
                        )
                        Text(section.title)
                            .font(Theme.mono(11.5, selection == section ? .semibold : .regular))
                            .foregroundStyle(selection == section ? Theme.text : Theme.textDim)
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(
                        selection == section ? Theme.panelActive : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("extensions.section.\(section.rawValue)")
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 184)
        .background(Theme.panel.opacity(0.35))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
                .frame(height: 28)

            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selection.title)
                        .font(Theme.mono(18, .bold))
                        .foregroundStyle(Theme.text)
                    Text(selection.description)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
            }

            emptyState
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensions.content.\(selection.rawValue)")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            TablerIcon(name: selection.iconName, size: 28, color: Theme.textFaint)
            Text(selection.title)
                .font(Theme.mono(13, .semibold))
                .foregroundStyle(Theme.text)
            Text("Bu bölüm extension veri modeliyle birlikte etkinleşecek.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .panel()
    }
}

private struct ExtensionsWindowFrame: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            _ = window.setFrameUsingName("UncoilExtensionsWindow", force: true)
            window.setFrameAutosaveName("UncoilExtensionsWindow")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
