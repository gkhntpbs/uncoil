import SwiftUI
import AppKit

private struct PresetEditorRequest: Identifiable {
    let id = UUID()
    let preset: SessionPreset?
}

/// Settings → Agent Ayarları: per-provider terminal behavior toggles and the
/// command-palette hotkey. The Shift+Enter toggle sends a literal newline
/// (backslash + CR), which Claude Code and the Codex TUI accept for an in-prompt
/// newline. Applies live to open sessions (the terminal reads the setting on
/// each key event).
struct AgentBehaviorSettingsSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var presetEditorRequest: PresetEditorRequest?
    @State private var confirmingTranscriptClear = false

    private let providers: [AgentProvider] = [.claude, .codex]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            quitBehavior
            workingModes
            presetSection
            transcriptSection
            keyboardBehavior
            hotkeySection
        }
        .sheet(item: $presetEditorRequest) { request in
            SessionPresetEditorSheet(preset: request.preset) { preset in
                settings.upsertPreset(preset)
            }
        }
        .confirmationDialog(
            "Tüm session transcriptleri silinsin mi?",
            isPresented: $confirmingTranscriptClear
        ) {
            Button("Transcriptleri Sil", role: .destructive) {
                settings.clearTranscripts()
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Bu işlem geri alınamaz ve saklanan hassas terminal çıktılarının tamamını kaldırır.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.agentBehavior.container")
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session transcriptleri")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Terminal çıktılarının diskte ne kadar süre saklanacağını seç. Varsayılan olarak kayıt kapalıdır.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            HStack(spacing: 10) {
                TablerIcon(name: "file-text", size: 12, color: Theme.textDim)
                Text("Saklama süresi")
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Picker("", selection: Binding(
                    get: { settings.transcriptRetentionPolicy },
                    set: { settings.setTranscriptRetentionPolicy($0) }
                )) {
                    ForEach(TranscriptRetentionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
                .accessibilityIdentifier("settings.transcripts.retention")
                Button("Tümünü Temizle") {
                    confirmingTranscriptClear = true
                }
                .buttonStyle(.plain)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.danger)
                .accessibilityIdentifier("settings.transcripts.clear")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .panel()
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session presetleri")
                        .font(Theme.mono(12, .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Alt agent’ların sağlayıcı, başlangıç promptu ve yetki sınırlarını düzenle.")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                Button("Sıfırla") {
                    settings.resetPresets()
                }
                .buttonStyle(.plain)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textDim)
                .accessibilityIdentifier("settings.presets.reset")
                Button {
                    presetEditorRequest = PresetEditorRequest(preset: nil)
                } label: {
                    Label("Ekle", systemImage: "plus")
                        .font(Theme.mono(10.5, .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("settings.presets.add")
            }

            VStack(spacing: 0) {
                ForEach(Array(settings.presets.enumerated()), id: \.element.id) { index, preset in
                    HStack(spacing: 10) {
                        ProviderMark(provider: preset.provider, size: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(Theme.mono(12, .medium))
                                .foregroundStyle(Theme.text)
                            Text("\(preset.id) · \(preset.grantedCapabilities.count) yetki")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.textFaint)
                        }
                        Spacer()
                        Button("Düzenle") {
                            presetEditorRequest = PresetEditorRequest(preset: preset)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                        .accessibilityIdentifier("settings.presets.edit.\(preset.id)")
                        Button {
                            settings.removePreset(id: preset.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.danger)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.presets.delete.\(preset.id)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    if index != settings.presets.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel()
        }
    }

    private var quitBehavior: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Uygulama kapanışı")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Uncoil’den çıkıldığında çalışan oturumlara ne olacağını seç.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            VStack(spacing: 0) {
                ForEach(Array(SessionQuitBehavior.allCases.enumerated()), id: \.element) {
                    index,
                    behavior in
                    Button {
                        settings.setSessionQuitBehavior(behavior)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: settings.sessionQuitBehavior == behavior
                                ? "largecircle.fill.circle"
                                : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(
                                    settings.sessionQuitBehavior == behavior
                                        ? Theme.highlight : Theme.textFaint
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(behavior.title)
                                    .font(Theme.mono(12, .medium))
                                    .foregroundStyle(Theme.text)
                                Text(behavior.detail)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.textFaint)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "settings.agentBehavior.quit.\(behavior.rawValue)"
                    )
                    .accessibilityValue(
                        settings.sessionQuitBehavior == behavior ? "selected" : "not selected"
                    )
                    if index != SessionQuitBehavior.allCases.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel()
        }
    }

    private var workingModes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Varsayılan agent modu")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Her agent kendi desteklediği modlarla gösterilir. Yeni oturumlar seçilen modda başlar.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            VStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    workingModeRow(provider)
                    if index != providers.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel()
        }
    }

    private var keyboardBehavior: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Klavye davranışı")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Shift+Enter (ve Option+Enter) prompt içinde satır atlar; agent'a "
                 + "gönderim yerine ters bölü + satır başı (\\⏎) yollar. Açık "
                 + "oturumlara anında uygulanır.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            VStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    providerRow(provider)
                    if index != providers.count - 1 {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel()
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Klavye kısayolları")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Komut paletini açan kısayol. En az bir değiştirici tuş (⌘⌥⌃⇧) "
                 + "gerekir. Değişiklik anında uygulanır.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            HStack(spacing: 10) {
                TablerIcon(name: "command", size: 12, color: Theme.textDim)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Komut paleti")
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(Theme.text)
                    Text("Paleti aç / kapat")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                HotkeyRecorder(
                    binding: settings.commandPaletteHotkey,
                    onCapture: { settings.setCommandPaletteHotkey($0) }
                )
                Button {
                    settings.resetCommandPaletteHotkey()
                } label: {
                    Text("Sıfırla")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.hotkey.palette.reset")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .panel()
        }
    }

    private func providerRow(_ provider: AgentProvider) -> some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider, size: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(Theme.text)
                Text("Shift+Enter yeni satır")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { settings.shiftEnterNewline(for: provider) },
                set: { settings.setShiftEnterNewline($0, for: provider) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityIdentifier("settings.agentBehavior.shiftEnter.\(provider.rawValue)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func workingModeRow(_ provider: AgentProvider) -> some View {
        let selected = settings.workingMode(for: provider)
        return HStack(spacing: 10) {
            ProviderMark(provider: provider, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(Theme.text)
                Text(selected.detail(for: provider))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(2)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { settings.workingMode(for: provider) },
                set: { settings.setWorkingMode($0, for: provider) }
            )) {
                ForEach(AgentWorkingMode.options(for: provider)) { mode in
                    Text(mode.label(for: provider)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 220)
            .accessibilityIdentifier("settings.agentBehavior.workingMode.\(provider.rawValue)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct SessionPresetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preset: SessionPreset?
    let onSave: (SessionPreset) -> Void

    @State private var id: String
    @State private var name: String
    @State private var provider: AgentProvider
    @State private var argumentsText: String
    @State private var prompt: String
    @State private var permissionMode: String
    @State private var capabilities: Set<String>

    init(preset: SessionPreset?, onSave: @escaping (SessionPreset) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _id = State(initialValue: preset?.id ?? "")
        _name = State(initialValue: preset?.name ?? "")
        _provider = State(initialValue: preset?.provider ?? .claude)
        _argumentsText = State(initialValue: preset?.extraArguments.joined(separator: "\n") ?? "")
        _prompt = State(initialValue: preset?.initialPromptTemplate ?? "")
        _permissionMode = State(initialValue: preset?.permissionMode ?? "standard")
        _capabilities = State(initialValue: Set(
            preset?.grantedCapabilities ?? Array(PolicyEngine.defaultGrants)
        ))
    }

    private var normalizedID: String {
        id.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private var canSave: Bool {
        !normalizedID.isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !permissionMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var initialPromptTemplate: String? {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preset == nil ? "Preset Ekle" : "Preset Düzenle")
                .font(Theme.mono(15, .semibold))
                .foregroundStyle(Theme.text)

            Form {
                TextField("Kimlik", text: $id)
                    .disabled(preset != nil)
                    .accessibilityIdentifier("settings.presets.editor.id")
                TextField("Ad", text: $name)
                    .accessibilityIdentifier("settings.presets.editor.name")
                Picker("Sağlayıcı", selection: $provider) {
                    ForEach([AgentProvider.claude, .codex]) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                TextField("Permission modu", text: $permissionMode)
                TextField("CLI argümanları (satır başına bir tane)", text: $argumentsText, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Başlangıç promptu", text: $prompt, axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.grouped)

            Text("Yetkiler")
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(Theme.textDim)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(CapabilityCatalog.all) { capability in
                        Toggle(isOn: Binding(
                            get: { capabilities.contains(capability.key) },
                            set: { enabled in
                                if enabled {
                                    capabilities.insert(capability.key)
                                } else {
                                    capabilities.remove(capability.key)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(capability.label)
                                    .font(Theme.mono(11.5, .medium))
                                Text(capability.key)
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings.presets.editor.capability.\(capability.key)")
                    }
                }
            }
            .frame(height: 190)

            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Kaydet") {
                    let newPreset = SessionPreset(
                        id: normalizedID,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        provider: provider,
                        extraArguments: argumentsText
                            .split(separator: "\n")
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty },
                        initialPromptTemplate: initialPromptTemplate,
                        grantedCapabilities: capabilities.sorted(),
                        permissionMode: permissionMode
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    onSave(newPreset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("settings.presets.editor.save")
            }
        }
        .padding(20)
        .frame(width: 560, height: 650)
        .background(Theme.bg)
    }
}

/// A pill button that shows the current shortcut and, when clicked, records the
/// next key+modifier chord via a temporary local key monitor. Rejects bare keys
/// (needs ≥1 modifier) and cancels on Escape.
private struct HotkeyRecorder: View {
    let binding: HotkeyBinding
    let onCapture: (HotkeyBinding) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if recording { stop() } else { start() }
        } label: {
            Text(recording ? "Tuşa basın…" : binding.displayString)
                .font(Theme.mono(12, .medium))
                .foregroundStyle(recording ? Theme.text : Theme.textDim)
                .frame(minWidth: 52)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(recording ? Theme.panelActive : Theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(recording ? Theme.highlight : Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hotkey.palette.recorder")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels recording without changing the binding.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let mods = HotkeyBinding.canonicalizeModifiers(event.modifierFlags.rawValue)
            // Require at least one real modifier; ignore bare keys so the user
            // keeps pressing until they add one.
            guard mods != 0 else { return nil }
            onCapture(HotkeyBinding(keyCode: event.keyCode, modifiers: mods))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
