import SwiftUI

/// Attention Center: everything that wants the user — permission prompts,
/// agents waiting on an answer, finished turns, failing tests, merge
/// conflicts, logins and runtime trouble — with one action per row that jumps
/// to the session it came from.
struct AttentionCenterView: View {
    @ObservedObject private var store = AttentionStore.shared
    let onOpen: (AttentionItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if store.items.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: 372)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.panel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            TablerIcon(name: "bell", size: 13, color: Theme.textDim)
            Text("Dikkat Merkezi")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            if store.unreadCount > 0 {
                Text("\(store.unreadCount)")
                    .font(Theme.mono(9.5, .semibold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Theme.claude, in: Capsule())
            }
            Spacer()
            if !store.items.isEmpty {
                Button("Okundu") { store.markAllRead() }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("attention.markAllRead")
                Button("Temizle") { store.resolveAll() }
                    .buttonStyle(GhostButtonStyle())
                    .accessibilityIdentifier("attention.resolveAll")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            TablerIcon(name: "circle-check", size: 22, color: Theme.textFaint)
            Text("Bekleyen bir şey yok")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .accessibilityIdentifier("attention.empty")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.items) { item in
                    AttentionRow(
                        item: item,
                        onOpen: {
                            store.markRead(item.id)
                            onOpen(item)
                        },
                        onResolve: { store.resolve(item.id) }
                    )
                }
            }
            .padding(8)
            .uncoilScrollers()
        }
        .frame(maxHeight: 380)
    }
}

private struct AttentionRow: View {
    let item: AttentionItem
    let onOpen: () -> Void
    let onResolve: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            TablerIcon(name: item.kind.iconName, size: 14, color: item.kind.color)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.kind.label)
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(item.kind.color)
                    if !item.isRead {
                        Circle()
                            .fill(item.kind.color)
                            .frame(width: 4.5, height: 4.5)
                    }
                    Spacer(minLength: 2)
                    Text(RelativeClock.short(since: item.createdAt))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textFaint)
                }
                Text(item.title)
                    .font(Theme.mono(11.5, item.isRead ? .regular : .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onResolve) {
                TablerIcon(
                    name: "check",
                    size: 12,
                    color: hovering ? Theme.text : Theme.textFaint
                )
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Çözüldü olarak işaretle")
            .accessibilityIdentifier("attention.resolve.\(item.id)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            hovering ? Theme.panelHover : (item.isRead ? .clear : Theme.panel.opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("attention.item.\(item.id)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onOpen)
    }
}

/// Sidebar rail bell with an unread badge; opens the Attention Center.
struct AttentionRailButton: View {
    let onOpen: (AttentionItem) -> Void
    @ObservedObject private var store = AttentionStore.shared
    @State private var showPanel = false
    @State private var hovering = false

    var body: some View {
        Button {
            showPanel = true
        } label: {
            ZStack(alignment: .topTrailing) {
                TablerIcon(
                    name: store.items.isEmpty ? "bell" : "bell-ringing",
                    size: 13,
                    color: badgeColor ?? (hovering ? Theme.text : Theme.textDim)
                )
                .frame(width: 24, height: 24)
                .background(hovering ? Theme.panelHover : .clear, in: RoundedRectangle(cornerRadius: 6))
                if store.unreadCount > 0 {
                    Circle()
                        .fill(badgeColor ?? Theme.claude)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(
            store.unreadCount > 0
                ? "\(store.unreadCount) bekleyen bildirim"
                : "Dikkat merkezi"
        )
        .accessibilityIdentifier("sidebar.attentionButton")
        .accessibilityValue("\(store.unreadCount)")
        .popover(isPresented: $showPanel, arrowEdge: .top) {
            AttentionCenterView { item in
                showPanel = false
                onOpen(item)
            }
        }
    }

    private var badgeColor: Color? {
        store.items
            .filter { !$0.isRead }
            .max { $0.kind.priority < $1.kind.priority }?
            .kind.color
    }
}
