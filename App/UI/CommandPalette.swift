import SwiftUI
import AppKit

/// VS Code–style command palette overlaid on the main window. Keyboard-first:
/// ⌘K toggles, Esc closes, ↑/↓ navigate, Enter runs. Presentation only — the
/// model computes results, MainWindow performs the chosen action.
struct CommandPaletteOverlay: View {
    @ObservedObject var model: PaletteModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Dimmed backdrop — click to dismiss.
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.close() }

                panel
                    .frame(width: 560)
                    .padding(.top, max(72, geo.size.height * 0.15))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity)
        .onAppear { focusSearchField() }
    }

    /// Moves keyboard focus into the search field on open. The overlay mounts
    /// fresh each time (conditional in MainWindow's ZStack), but a SwiftTerm
    /// NSView usually holds first responder and SwiftUI's @FocusState does not
    /// reliably take on the same runloop turn the overlay is inserted. Resign
    /// the current responder, then assert focus across a few turns so the field
    /// wins every time — and re-assert if the responder is stolen back.
    private func focusSearchField() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        searchFocused = true
        for delay in [0.02, 0.06, 0.15, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !searchFocused { searchFocused = true }
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Theme.border)
            results
        }
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("palette.container")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            TablerIcon(name: "search", size: 14, color: Theme.textDim)
            TextField("Komut ara, dosya bul, projeye git…", text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.mono(14))
                .foregroundStyle(Theme.text)
                .focused($searchFocused)
                .accessibilityIdentifier("palette.searchField")
            if !model.query.isEmpty {
                Text("\(model.flatItems.count)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.flatItems.isEmpty {
                        Text("Sonuç yok")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 28)
                    }
                    let flat = flatWithIndices()
                    ForEach(model.groups) { group in
                        Text(group.title.uppercased())
                            .font(Theme.mono(9.5, .semibold))
                            .foregroundStyle(Theme.textFaint)
                            .kerning(0.7)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 3)
                        ForEach(group.items) { item in
                            let index = flat[item.id] ?? 0
                            PaletteRow(item: item, selected: index == model.selectedIndex)
                                .id(index)
                                .accessibilityIdentifier("palette.result.\(index)")
                                .onTapGesture { model.execute(item) }
                                .onHover { if $0 { model.selectedIndex = index } }
                        }
                    }
                }
                .padding(.bottom, 8)
                .uncoilScrollers()
            }
            .frame(maxHeight: 380)
            .onChange(of: model.selectedIndex) { _, new in
                withAnimation(uncoilAnimation(.easeOut(duration: 0.12))) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private func flatWithIndices() -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, item) in model.flatItems.enumerated() { map[item.id] = index }
        return map
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let provider = item.provider {
                    ProviderMark(provider: provider, size: 13)
                } else {
                    TablerIcon(name: item.iconName, size: 14,
                               color: selected ? Theme.text : Theme.textDim)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(selected ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if let status = item.status {
                StatusOrb(status: status, size: 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            selected ? Theme.panelActive : .clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

/// Installs (once) a local key monitor so ⌘K works even while a SwiftTerm view
/// holds first responder (terminal views swallow key equivalents). While the
/// palette is open it also owns Esc / ↑ / ↓ / Enter so navigation beats the
/// focused text field.
@MainActor
enum PaletteHotkeyMonitor {
    private static var installed = false

    static func install(model: PaletteModel, settings: SettingsStore) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model, weak settings] event in
            guard let model, let settings else { return event }

            // The configurable palette hotkey toggles — read live so a rebind
            // applies without restart. Suppressed in settings / popout windows.
            let binding = settings.commandPaletteHotkey
            if binding.matches(keyCode: event.keyCode,
                               modifiers: event.modifierFlags.rawValue),
               !isAuxiliaryWindow(event.window) {
                model.toggle()
                return nil
            }

            guard model.isOpen else { return event }
            switch event.keyCode {
            case 53: model.close(); return nil                       // Escape
            case 125: model.move(1); return nil                      // Down
            case 126: model.move(-1); return nil                     // Up
            case 36, 76: model.executeSelected(); return nil         // Return / Enter
            default: return event
            }
        }
    }

    private static func isAuxiliaryWindow(_ window: NSWindow?) -> Bool {
        guard let title = window?.title else { return false }
        return title.contains("Ayarları") || title.contains("Oturum")
    }
}
