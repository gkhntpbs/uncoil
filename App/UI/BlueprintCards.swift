import SwiftUI

/// Opens a session and hands it a blueprint's prompt.
///
/// Uncoil creates nothing on disk. That is the design, not a shortcut: whether
/// `api/` should hold a Fastify skeleton or a Go module, and what this project's
/// `CLAUDE.md` should actually say, is judgement — and judgement is what the
/// agent is there for. A tree stamped out by the app would still need all of it
/// applied afterwards.
@MainActor
enum BlueprintRunner {
    @discardableResult
    static func apply(
        _ blueprint: Blueprint,
        to project: Project,
        settings: SettingsStore,
        sessionStore: SessionStore,
        projectStore: ProjectStore
    ) -> SessionRecord {
        // The default agent, from Settings. A blueprint says what to do, not
        // who should do it: the user already chose their agent once and should
        // not have to choose again per blueprint.
        let provider = settings.defaultProvider
        let record = projectStore.createSession(
            projectID: project.id,
            provider: provider,
            accountID: provider.isAgent
                ? settings.defaultAccount(for: provider)?.id : nil,
            title: String(localized: "\(provider.rawValue): \(blueprint.name)")
        )
        Router.shared.go(to: .session(record.id))
        SessionPromptDelivery.deliver(
            blueprint.resolvedPrompt(for: project),
            to: record, project: project,
            settings: settings, sessionStore: sessionStore, projectStore: projectStore,
            // A blueprint that has not said it may start on its own is typed in
            // and left. Reading it before it runs is the point of the switch.
            autoStart: blueprint.startsImmediately
        )
        return record
    }
}

/// The mark a blueprint shows: its own icon and colour, or a neutral default.
struct BlueprintMark: View {
    var iconName: String?
    var colorHex: UInt32?
    var fallback = "square.grid.2x2"
    var size: CGFloat = 15

    var body: some View {
        let accent = colorHex.map { Color(hex: $0) } ?? Theme.textDim
        Group {
            if let iconName {
                TablerIcon(name: iconName, size: size + 2, color: accent)
            } else {
                Image(systemName: fallback)
                    .font(.system(size: size))
                    .foregroundStyle(accent)
            }
        }
    }
}

/// "How should this project start?" — Default, then the blueprints.
///
/// Rows rather than a grid of tiles: what decides the choice is the first line
/// of the prompt, and a tile has nowhere to put it.
struct BlueprintChooser: View {
    @ObservedObject var store: BlueprintStore
    /// nil = Default, i.e. do nothing at all.
    @Binding var selected: String?
    /// Offered when there are none yet, so the list is never dead space.
    var onWriteFirst: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.tight) {
            SheetOptionRow(
                title: String(localized: "Default"),
                detail: String(localized: "Add the folder and nothing else."),
                isSelected: selected == nil
            ) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textDim)
            } action: {
                selected = nil
            }
            .accessibilityIdentifier("blueprint.card.default")

            ForEach(store.blueprints) { blueprint in
                SheetOptionRow(
                    title: blueprint.name,
                    detail: blueprint.prompt,
                    badge: blueprint.needsReview ? String(localized: "draft") : nil,
                    isSelected: selected == blueprint.id
                ) {
                    BlueprintMark(
                        iconName: blueprint.iconName, colorHex: blueprint.colorHex
                    )
                } action: {
                    selected = blueprint.id
                }
                .accessibilityIdentifier("blueprint.card.\(blueprint.id)")
            }

            if store.blueprints.isEmpty, let onWriteFirst {
                Button(action: onWriteFirst) {
                    HStack(spacing: Theme.Space.tight) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                        Text("Write a blueprint")
                            .font(Theme.ui(.body, .medium))
                    }
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.snug)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.panel)
                            .strokeBorder(
                                Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("blueprint.card.new")
            }
        }
    }
}

/// Applying a blueprint to a project that already exists — from the sidebar's
/// context menu or the command palette.
struct ApplyBlueprintSheet: View {
    let project: Project
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var projectStore: ProjectStore
    @ObservedObject private var store = BlueprintStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selected: String?
    @State private var editing: Blueprint?

    var body: some View {
        SheetScaffold(
            title: String(localized: "Apply a Blueprint"),
            subtitle: String(localized: "Opens a session in \(project.name) with \(settings.defaultProvider.displayName) and gives it the prompt.")
        ) {
            ScrollView {
                VStack(spacing: Theme.Space.tight) {
                    if store.blueprints.isEmpty {
                        Text("No blueprints yet. Settings › Agents › Blueprints is where they are written.")
                            .font(Theme.ui(.body))
                            .foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(store.blueprints) { blueprint in
                            SheetOptionRow(
                                title: blueprint.name,
                                detail: blueprint.prompt,
                                badge: blueprint.needsReview
                                    ? String(localized: "draft") : nil,
                                isSelected: selected == blueprint.id
                            ) {
                                BlueprintMark(
                                    iconName: blueprint.iconName,
                                    colorHex: blueprint.colorHex
                                )
                            } action: {
                                selected = blueprint.id
                            }
                            .accessibilityIdentifier("blueprint.apply.\(blueprint.id)")
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.section)
            }
            .uncoilScrollers()
            .frame(maxHeight: 320)
        } actions: {
            Button(String(localized: "Cancel")) { dismiss() }
                .buttonStyle(GhostButtonStyle())
            Spacer()
            if let selected, let blueprint = store.blueprint(id: selected) {
                Button(String(localized: "Edit…")) { editing = blueprint }
                    .buttonStyle(GhostButtonStyle())
            }
            Button(String(localized: "Apply")) {
                if let selected, let blueprint = store.blueprint(id: selected) {
                    BlueprintRunner.apply(
                        blueprint, to: project, settings: settings,
                        sessionStore: sessionStore, projectStore: projectStore
                    )
                }
                dismiss()
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(selected == nil)
            .accessibilityIdentifier("blueprint.apply.confirm")
        }
        .sheet(item: $editing) { blueprint in
            BlueprintEditorSheet(blueprint: blueprint, store: store)
        }
        .task { store.reload() }
    }
}
