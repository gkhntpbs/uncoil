import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var hookStatus = HookInstaller.status()
    @State private var hookMessage: String?
    @State private var newAccountName = ""
    @State private var addingAccountFor: AgentProvider?
    @State private var githubTokenDraft = ""
    @State private var githubTokenSaved = KeychainStore.read(key: "github-token") != nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer().frame(height: 26)

                Text("Ayarlar")
                    .font(Theme.mono(16, .bold))
                    .foregroundStyle(Theme.text)

                accountsSection(.claude)
                accountsSection(.codex)
                defaultsSection
                cliToolsSection
                launchArgsSection
                githubSection
                hooksSection
            }
            .padding(20)
            .uncoilScrollers()
            .accessibilityIdentifier("settings.container")
        }
        .frame(width: 480, height: 640)
        .background(Theme.bg)
        .accessibilityIdentifier("settings.container")
    }

    // MARK: - Accounts

    private func accountsSection(_ provider: AgentProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderMark(provider: provider, size: 12)
                Text("\(provider.displayName) Hesapları")
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    addingAccountFor = provider
                    newAccountName = ""
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 1) {
                ForEach(settings.accounts(for: provider)) { profile in
                    AccountRow(profile: profile)
                }
            }
            .panel()

            if addingAccountFor == provider {
                HStack(spacing: 8) {
                    TextField("Hesap adı (ör. İş, Kişisel)", text: $newAccountName)
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
                    Button("Ekle") {
                        let trimmed = newAccountName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        settings.addAccount(provider: provider, name: trimmed)
                        addingAccountFor = nil
                    }
                    .buttonStyle(AccentButtonStyle())
                    Button("Vazgeç") { addingAccountFor = nil }
                        .buttonStyle(GhostButtonStyle())
                }
            }
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Varsayılanlar")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)

            VStack(spacing: 0) {
                HStack {
                    Text("Varsayılan agent")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach([AgentProvider.claude, .codex]) { provider in
                            Button {
                                settings.defaultProvider = provider
                                settings.save()
                            } label: {
                                Text(provider.displayName)
                                    .font(Theme.mono(11, .medium))
                                    .foregroundStyle(
                                        settings.defaultProvider == provider ? Theme.text : Theme.textFaint
                                    )
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        settings.defaultProvider == provider ? Theme.panelActive : .clear,
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                }
                .padding(12)

                Divider().overlay(Theme.border)

                ForEach([AgentProvider.claude, .codex]) { provider in
                    HStack {
                        Text("\(provider.displayName) CLI")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textDim)
                        Spacer()
                        Text(settings.binaryPath(for: provider) ?? "bulunamadı")
                            .font(Theme.mono(11))
                            .foregroundStyle(
                                settings.binaryPath(for: provider) == nil ? Theme.danger : Theme.textFaint
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .panel()
        }
    }

    // MARK: - CLI tools

    private var cliToolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLI Araçları")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Kurulu sürümleri kontrol et ve tek tıkla güncelle.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            VStack(spacing: 0) {
                ForEach([AgentProvider.claude, .codex]) { provider in
                    CLIToolRow(provider: provider)
                    if provider != .codex {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel()
        }
        .task { await settings.refreshCLIVersions() }
    }

    // MARK: - Launch arguments

    private var launchArgsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Çalıştırma Parametreleri")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Agent başlatılırken komuta eklenir; bir sonraki oturumdan itibaren geçerli.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            VStack(spacing: 0) {
                ForEach([AgentProvider.claude, .codex]) { provider in
                    HStack(spacing: 10) {
                        ProviderMark(provider: provider, size: 12)
                        Text(provider.displayName)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textDim)
                            .frame(width: 60, alignment: .leading)
                        TextField(
                            provider == .claude ? "ör. --model opus" : "ör. --full-auto",
                            text: Binding(
                                get: { settings.extraArguments[provider.rawValue] ?? "" },
                                set: { settings.extraArguments[provider.rawValue] = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.text)
                        .onSubmit { settings.save() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    if provider != .codex {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            .panel()
            .onDisappear { settings.save() }
        }
    }

    // MARK: - GitHub

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Token yalnızca Keychain'de saklanır; özel depoların PR'ları için gerekir.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            HStack(spacing: 8) {
                if githubTokenSaved {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.ok).frame(width: 6, height: 6)
                        Text("Token kayıtlı")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Button("Sil") {
                        KeychainStore.delete(key: "github-token")
                        githubTokenSaved = false
                    }
                    .buttonStyle(GhostButtonStyle())
                } else {
                    SecureField("ghp_… kişisel erişim token'ı", text: $githubTokenDraft)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                    Button("Kaydet") {
                        let trimmed = githubTokenDraft.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        KeychainStore.save(key: "github-token", value: trimmed)
                        githubTokenDraft = ""
                        githubTokenSaved = true
                    }
                    .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(githubTokenSaved ? 12 : 0)
            .background(githubTokenSaved ? Theme.panel : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(githubTokenSaved ? Theme.border : .clear, lineWidth: 1)
            )
        }
    }

    // MARK: - Hooks

    private var hooksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Durum Takibi (hooks)")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(hookStatus == .installed ? Theme.ok : Theme.warn)
                        .frame(width: 7, height: 7)
                    Text(hookStatusLabel)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    if hookStatus == .installed {
                        Button("Kaldır") { runHook(install: false) }
                            .buttonStyle(GhostButtonStyle())
                    } else {
                        Button("Kur") { runHook(install: true) }
                            .buttonStyle(AccentButtonStyle())
                    }
                }
                .padding(12)

                if let hookMessage {
                    Divider().overlay(Theme.border)
                    Text(hookMessage)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .panel()
        }
    }

    private var hookStatusLabel: String {
        switch hookStatus {
        case .installed: "Kurulu — durumlar canlı akıyor"
        case .notInstalled: "Kurulu değil"
        case .partiallyInstalled(let missing): "Eksik: \(missing.joined(separator: ", "))"
        }
    }

    private func runHook(install: Bool) {
        do {
            if install {
                try HookInstaller.install()
                hookMessage = "settings.json güncellendi; yedeği config-backups/ altında. Açık Claude oturumlarını yeniden başlat."
            } else {
                try HookInstaller.uninstall()
                hookMessage = "Uncoil girdileri kaldırıldı; diğer hook'lara dokunulmadı."
            }
        } catch {
            hookMessage = error.localizedDescription
        }
        hookStatus = HookInstaller.status()
    }
}

private struct CLIToolRow: View {
    let provider: AgentProvider
    @EnvironmentObject private var settings: SettingsStore

    private var path: String? { settings.binaryPath(for: provider) }
    private var updating: Bool { settings.cliUpdating.contains(provider.rawValue) }

    private var sourceLabel: String? {
        path.map { CLIToolService.source(forBinaryAt: $0, provider: provider).label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ProviderMark(provider: provider, size: 12)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(Theme.mono(12, .medium))
                            .foregroundStyle(Theme.text)
                        if let sourceLabel {
                            Text(sourceLabel)
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.textFaint)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.panelActive, in: Capsule())
                        }
                    }
                    Text(settings.cliVersions[provider.rawValue] ?? (path == nil ? "kurulu değil" : "sürüm okunuyor…"))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(path == nil ? Theme.danger : Theme.textFaint)
                        .lineLimit(1)
                }
                Spacer()
                if updating {
                    ProgressView()
                        .controlSize(.small)
                    Text("güncelleniyor…")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                } else {
                    Button("Kontrol Et") {
                        Task { await settings.refreshCLIVersions() }
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button("Güncelle") {
                        Task { await settings.updateCLI(provider) }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(path == nil)
                }
            }
            if let result = settings.cliUpdateResult[provider.rawValue] {
                Text(result)
                    .font(Theme.mono(10))
                    .foregroundStyle(result.hasPrefix("✓") ? Theme.ok : Theme.danger)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct AccountRow: View {
    let profile: AccountProfile
    @EnvironmentObject private var settings: SettingsStore
    @State private var email: String?

    private var isDefault: Bool {
        settings.defaultAccount(for: profile.provider)?.id == profile.id
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(Theme.text)
                    if isDefault {
                        Text("varsayılan")
                            .font(Theme.mono(9, .semibold))
                            .foregroundStyle(profile.provider.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(profile.provider.color.opacity(0.12), in: Capsule())
                    }
                }
                Text(email ?? "giriş yapılmamış — oturum başlatınca provider login akışı açılır")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(email == nil ? Theme.textFaint : Theme.ok)
            }
            Spacer()
            if !isDefault {
                Button("Varsayılan yap") { settings.setDefaultAccount(profile) }
                    .buttonStyle(GhostButtonStyle())
            }
            if profile.directoryName != nil {
                Button {
                    settings.removeAccount(profile)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .task(id: profile.id) {
            guard profile.provider == .claude else { return }
            let root = settings.profilesRootURL
            let store = settings
            let value = await Task.detached(priority: .utility) {
                store.loggedInEmail(for: profile, profilesRoot: root)
            }.value
            email = value
        }
    }
}
