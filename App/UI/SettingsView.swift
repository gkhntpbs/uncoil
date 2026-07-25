import SwiftUI

/// Cross-window channel so the command palette can deep-link to a settings pane.
@MainActor
final class SettingsRoute: ObservableObject {
    static let shared = SettingsRoute()
    @Published var requestedPane: String?
}

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var theme: ThemeStore
    @State private var hookStatus = HookInstaller.status()
    @State private var hookMessage: String?
    @State private var newAccountName = ""
    @State private var addingAccountFor: AgentProvider?
    @State private var githubTokenSaved = KeychainStore.read(key: "github-token") != nil

    enum Pane: String, CaseIterable, Identifiable {
        case accounts
        case defaults
        case cliTools
        case launchArgs
        case agentBehavior
        case notifications
        case theme
        case github
        case hooks
        case permissions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accounts: "Hesaplar"
            case .defaults: "Varsayılanlar"
            case .cliTools: "CLI Araçları"
            case .launchArgs: "Parametreler"
            case .agentBehavior: "Agent Ayarları"
            case .notifications: "Bildirimler"
            case .theme: "Tema"
            case .github: "GitHub"
            case .hooks: "Hooks"
            case .permissions: "İzinler"
            }
        }

        var iconName: String {
            switch self {
            case .accounts: "users"
            case .defaults: "adjustments"
            case .cliTools: "terminal-2"
            case .launchArgs: "command"
            case .agentBehavior: "keyboard"
            case .notifications: "bell"
            case .theme: "palette"
            case .github: "brand-github"
            case .hooks: "webhook"
            case .permissions: "shield-lock"
            }
        }

        /// Search terms (Turkish + English) matched by the filter box.
        var keywords: String {
            switch self {
            case .accounts: "hesap account claude codex login giriş profil"
            case .defaults: "varsayılan default editör editor agent cli yol path"
            case .cliTools: "cli güncelle update sürüm version brew npm"
            case .launchArgs: "parametre argüman argument model flag"
            case .agentBehavior: "agent davranış behavior mod mode auto plan shift enter newline satır klavye keyboard"
            case .notifications: "bildirim notification ses sound öncelik priority"
            case .theme: "tema theme renk color açık koyu light dark terminal"
            case .github: "github token pr pull request giriş login"
            case .hooks: "hook durum status izleme kanca"
            case .permissions: "izin permission mcp grant onay agent kontrol"
            }
        }
    }

    @State private var pane: Pane = .accounts
    @State private var search = ""

    /// Identity is what makes a theme change reach views that read `Theme.*`,
    /// since those are static reads SwiftUI cannot track. The main window gets
    /// it from `ThemedWindow`; Settings cannot use that wholesale, because
    /// re-identifying the pane while a colour picker is open tears the picker
    /// out from under the drag.
    ///
    /// So the key is the whole palette everywhere except the Tema pane — the
    /// one place colours change continuously — where it is the mode alone. A
    /// preset switch still rebuilds; a single picker edit leaves identity
    /// alone and is carried by the surfaces that observe the store.
    private var paletteIdentity: AnyHashable {
        pane == .theme ? AnyHashable(theme.palette.isLight) : AnyHashable(theme.palette)
    }

    private var visiblePanes: [Pane] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Pane.allCases }
        return Pane.allCases.filter {
            $0.title.lowercased().contains(query) || $0.keywords.contains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Settings sidebar: search + pane list
            VStack(alignment: .leading, spacing: 8) {
                Spacer().frame(height: 34)

                HStack(spacing: 6) {
                    TablerIcon(name: "search", size: 11, color: Theme.textFaint)
                    TextField("Ara", text: $search)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
                .padding(.horizontal, 10)

                VStack(spacing: 1) {
                    ForEach(visiblePanes) { candidate in
                        SettingsPaneRow(
                            pane: candidate,
                            isSelected: pane == candidate
                        ) { pane = candidate }
                    }
                }
                .padding(.horizontal, 8)

                Spacer()
            }
            .frame(width: 170)

            Rectangle().fill(Theme.border).frame(width: 1)

            // Selected pane
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer().frame(height: 30)
                    Text(pane.title)
                        .font(Theme.mono(15, .bold))
                        .foregroundStyle(Theme.text)

                    switch pane {
                    case .accounts:
                        accountsSection(.claude)
                        accountsSection(.codex)
                    case .defaults:
                        defaultsSection
                    case .cliTools:
                        cliToolsSection
                    case .launchArgs:
                        launchArgsSection
                    case .agentBehavior:
                        AgentBehaviorSettingsSection()
                    case .notifications:
                        notificationsSection
                    case .theme:
                        ThemeSettingsSection()
                    case .github:
                        githubSection
                    case .hooks:
                        hooksSection
                    case .permissions:
                        if let service = sessionStore.permissionService {
                            PermissionsSettingsSection(service: service)
                        } else {
                            Text("Kontrol düzlemi çalışmıyor; izin isteği yok.")
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .uncoilScrollers()
            }
        }
        .id(paletteIdentity)
        .frame(width: 660, height: 620)
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.container")
        .onAppear { applyRequestedPane() }
        .onReceive(SettingsRoute.shared.$requestedPane) { _ in applyRequestedPane() }
    }

    private func applyRequestedPane() {
        guard let raw = SettingsRoute.shared.requestedPane,
              let requested = Pane(rawValue: raw) else { return }
        pane = requested
        search = ""
        SettingsRoute.shared.requestedPane = nil
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

                HStack {
                    Text("Editör")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Menu {
                        ForEach(PreferredEditor.allCases) { editor in
                            Button {
                                settings.preferredEditor = editor
                                settings.save()
                            } label: {
                                if editor.isInstalled {
                                    Text(editor.displayName)
                                } else {
                                    Text("\(editor.displayName) (kurulu değil)")
                                }
                            }
                        }
                    } label: {
                        Text(settings.preferredEditor.displayName)
                            .font(Theme.mono(11, .medium))
                            .foregroundStyle(Theme.text)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

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
        .task { await settings.checkCLIUpdates() }
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

    // MARK: - Notifications

    private var notificationsSection: some View {
        NotificationSettingsSection()
    }

    // MARK: - GitHub

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Tarayıcıdan giriş yap; token yalnızca Keychain'de saklanır.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            GitHubLoginView(loggedIn: $githubTokenSaved)
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
                } else if settings.cliChecking {
                    ProgressView().controlSize(.small)
                } else if settings.updateAvailable(for: provider) {
                    Text(settings.cliLatest[provider.rawValue].map { "yeni: \($0)" } ?? "")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.warn)
                    Button("Güncelle") {
                        Task { await settings.updateCLI(provider) }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(path == nil)
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.ok).frame(width: 6, height: 6)
                        Text("güncel")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textDim)
                    }
                    Button("Kontrol Et") {
                        Task { await settings.checkCLIUpdates() }
                    }
                    .buttonStyle(GhostButtonStyle())
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
    @State private var showLogin = false
    @State private var refreshToken = 0

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
            if profile.provider.loginCommand != nil, email == nil {
                Button("Giriş Yap") { showLogin = true }
                    .buttonStyle(AccentButtonStyle())
                    .accessibilityIdentifier("settings.account.loginButton.\(profile.name)")
            }
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
        .sheet(isPresented: $showLogin) {
            LoginTerminalSheet(profile: profile) {
                refreshToken += 1
            }
        }
        .task(id: "\(profile.id)-\(refreshToken)") {
            guard profile.provider != .terminal else { return }
            let root = settings.profilesRootURL
            let store = settings
            let value = await Task.detached(priority: .utility) {
                store.loggedInEmail(for: profile, profilesRoot: root)
            }.value
            email = value
        }
    }
}

// MARK: - GitHub browser login

/// Device-flow login: shows the one-time code, opens github.com in the
/// chosen browser, polls until authorized, stores the token in Keychain.
struct GitHubLoginView: View {
    @Binding var loggedIn: Bool
    @State private var phase: Phase = .idle
    @State private var username: String?
    @State private var pollTask: Task<Void, Never>?

    enum Phase: Equatable {
        case idle
        case requesting
        case waitingForBrowser(GitHubAuthService.DeviceCode)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loggedIn {
                loggedInRow
            } else {
                switch phase {
                case .idle, .failed:
                    startRow
                case .requesting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("GitHub'dan kod isteniyor…")
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.textDim)
                    }
                    .padding(12)
                case .waitingForBrowser(let code):
                    codeRow(code)
                }
                if case .failed(let message) = phase {
                    Text(message)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
        }
        .panel()
        .task {
            guard loggedIn, username == nil,
                  let token = KeychainStore.read(key: "github-token") else { return }
            username = await GitHubAuthService.fetchUsername(token: token)
        }
    }

    private var loggedInRow: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.ok).frame(width: 6, height: 6)
            Text(username.map { "@\($0)" } ?? "Giriş yapıldı")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.text)
            Spacer()
            Button("Çıkış Yap") {
                KeychainStore.delete(key: "github-token")
                loggedIn = false
                username = nil
                phase = .idle
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(12)
    }

    private var startRow: some View {
        HStack {
            Text("GitHub hesabınla bağlan")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Button("Tarayıcıdan Giriş Yap") { startLogin() }
                .buttonStyle(AccentButtonStyle())
                .accessibilityIdentifier("settings.github.loginButton")
        }
        .padding(12)
    }

    private func codeRow(_ code: GitHubAuthService.DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(code.userCode)
                    .font(Theme.mono(18, .bold))
                    .foregroundStyle(Theme.text)
                    .kerning(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.panelActive, in: RoundedRectangle(cornerRadius: 8))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                } label: {
                    TablerIcon(name: "copy", size: 13, color: Theme.textDim)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Kodu kopyala")
                Spacer()
                ProgressView().controlSize(.small)
            }

            Text("Kod panoya kopyalandı — aşağıdan bir tarayıcı seçip sayfaya yapıştır; onaylayınca otomatik bağlanır.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            HStack(spacing: 6) {
                Button("Varsayılanda Aç") {
                    NSWorkspace.shared.open(code.verificationURL)
                }
                .buttonStyle(AccentButtonStyle())

                ForEach(BrowserApp.installed) { browser in
                    Button {
                        browser.open(code.verificationURL)
                    } label: {
                        Group {
                            if let icon = browser.appIcon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 15, height: 15)
                            } else {
                                Text(browser.displayName).font(Theme.mono(10))
                            }
                        }
                        .frame(width: 26, height: 26)
                        .background(Theme.panelHover, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("\(browser.displayName) ile aç")
                }

                // Fallback when no browser was detected (or by preference):
                // copy the login link and open it anywhere.
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.verificationURL.absoluteString, forType: .string)
                } label: {
                    TablerIcon(name: "link", size: 13, color: Theme.textDim)
                        .frame(width: 26, height: 26)
                        .background(Theme.panelHover, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Giriş linkini kopyala")

                Spacer()
                Button("Vazgeç") {
                    pollTask?.cancel()
                    phase = .idle
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(12)
    }

    private func startLogin() {
        phase = .requesting
        pollTask = Task {
            switch await GitHubAuthService.requestDeviceCode() {
            case .failure(let error):
                phase = .failed(error.errorDescription ?? "Bağlantı hatası")
            case .success(let code):
                // Copy the code and open the page right away.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                phase = .waitingForBrowser(code)

                switch await GitHubAuthService.pollForToken(code) {
                case .success(let token):
                    KeychainStore.save(key: "github-token", value: token)
                    username = await GitHubAuthService.fetchUsername(token: token)
                    loggedIn = true
                    phase = .idle
                case .failure(let error):
                    if !Task.isCancelled {
                        phase = .failed(error.errorDescription ?? "Giriş tamamlanamadı")
                    }
                }
            }
        }
    }
}


// MARK: - Notification settings

private struct NotificationSettingsSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var projectStore: ProjectStore
    @AppStorage("menuBarMonitorEnabled") private var menuBarMonitorEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bildirimler")
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.text)
            Text("Her durum değişimi için yalnızca bir bildirim gönderilir.")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)

            NotificationPermissionRow()

            VStack(spacing: 0) {
                toggleRow(
                    "Menü çubuğu monitörü",
                    Binding(
                        get: { menuBarMonitorEnabled },
                        set: { menuBarMonitorEnabled = $0 }
                    )
                )
                Divider().overlay(Theme.border)
                toggleRow("Bildirimler açık", binding(\.enabled))
                Divider().overlay(Theme.border)
                toggleRow("İzin beklerken", binding(\.notifyPermission))
                toggleRow("Girdi beklerken", binding(\.notifyInput))
                toggleRow("Tur tamamlanınca", binding(\.notifyTurnCompleted))
                Divider().overlay(Theme.border)

                HStack {
                    Text("Öncelik")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    priorityPicker(
                        current: settings.notifications.priority
                    ) { newValue in
                        settings.notifications.priority = newValue
                        settings.save()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                HStack {
                    Text("Ses")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    soundPicker(
                        current: settings.notifications.sound
                    ) { newValue in
                        settings.notifications.sound = newValue
                        settings.save()
                        NotificationPrefs.preview(sound: newValue)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .panel()

            if !projectStore.projects.isEmpty {
                Text("Proje bazında")
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.textDim)
                    .padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(projectStore.projects) { project in
                        ProjectNotificationRow(project: project)
                        if project.id != projectStore.projects.last?.id {
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                .panel()
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<NotificationPrefs, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.notifications[keyPath: keyPath] },
            set: { newValue in
                settings.notifications[keyPath: keyPath] = newValue
                settings.save()
            }
        )
    }

    private func toggleRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

@MainActor
func priorityPicker(
    current: NotificationPrefs.Priority,
    onPick: @escaping (NotificationPrefs.Priority) -> Void
) -> some View {
    Menu {
        ForEach(NotificationPrefs.Priority.allCases) { priority in
            Button(priority.label) { onPick(priority) }
        }
    } label: {
        Text(current.label)
            .font(Theme.mono(11, .medium))
            .foregroundStyle(Theme.text)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
}

@MainActor
func soundPicker(
    current: String,
    onPick: @escaping (String) -> Void
) -> some View {
    Menu {
        Button("Varsayılan") { onPick("default") }
        Button("Sessiz") { onPick("none") }
        Divider()
        ForEach(NotificationPrefs.systemSounds, id: \.self) { name in
            Button(name) { onPick(name) }
        }
    } label: {
        Text(current == "default" ? "Varsayılan" : current == "none" ? "Sessiz" : current)
            .font(Theme.mono(11, .medium))
            .foregroundStyle(Theme.text)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
}

private struct ProjectNotificationRow: View {
    let project: Project
    @EnvironmentObject private var settings: SettingsStore

    private var override: NotificationPrefs.ProjectOverride {
        settings.notifications.perProject[project.id] ?? .init()
    }

    private func mutate(_ change: (inout NotificationPrefs.ProjectOverride) -> Void) {
        var value = override
        change(&value)
        settings.notifications.perProject[project.id] = value
        settings.save()
    }

    var body: some View {
        HStack(spacing: 10) {
            ProjectIcon(project: project, size: 11)
            Text(project.name)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()

            priorityPicker(
                current: override.priority ?? settings.notifications.priority
            ) { newValue in
                mutate { $0.priority = newValue }
            }

            soundPicker(
                current: override.sound ?? settings.notifications.sound
            ) { newValue in
                mutate { $0.sound = newValue }
                NotificationPrefs.preview(sound: newValue)
            }

            Toggle("", isOn: Binding(
                get: { override.enabled ?? true },
                set: { newValue in mutate { $0.enabled = newValue } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}


private struct SettingsPaneRow: View {
    let pane: SettingsView.Pane
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                TablerIcon(
                    name: pane.iconName,
                    size: 12,
                    color: isSelected ? Theme.text : Theme.textDim
                )
                Text(pane.title)
                    .font(Theme.mono(12, isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textDim)
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                isSelected ? Theme.panelActive : (hovering ? Theme.panelHover : .clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
    }
}

// MARK: - Theme settings

private struct ThemeSettingsSection: View {
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hazır temalar")
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(Theme.textDim)
            HStack(spacing: 8) {
                Button("Koyu") { theme.apply(preset: .dark) }
                    .buttonStyle(theme.palette.isLight ? AnyButtonStyle(GhostButtonStyle()) : AnyButtonStyle(AccentButtonStyle()))
                Button("Açık") { theme.apply(preset: .light) }
                    .buttonStyle(theme.palette.isLight ? AnyButtonStyle(AccentButtonStyle()) : AnyButtonStyle(GhostButtonStyle()))
                Spacer()
            }

            Text("Renkler")
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(Theme.textDim)
                .padding(.top, 6)

            VStack(spacing: 0) {
                colorRow("Arka plan", \.bg)
                Divider().overlay(Theme.border)
                colorRow("Panel", \.panel)
                colorRow("Kenarlık", \.border)
                Divider().overlay(Theme.border)
                colorRow("Metin", \.text)
                colorRow("Soluk metin", \.textDim)
                Divider().overlay(Theme.border)
                colorRow("Claude rengi", \.claude)
                colorRow("Codex rengi", \.codex)
                Divider().overlay(Theme.border)
                colorRow("Terminal arka planı", \.terminalBg)
                colorRow("Terminal metni", \.terminalFg)
            }
            .panel()

            Text("Terminal renkleri yeni açılan oturumlarda geçerli olur.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textFaint)
        }
    }

    private func colorRow(
        _ title: String,
        _ keyPath: WritableKeyPath<ThemePalette, UInt32>
    ) -> some View {
        HStack {
            Text(title)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textDim)
            Spacer()
            ColorPicker("", selection: theme.binding(keyPath), supportsOpacity: false)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Type-erased button style so preset buttons can swap styles dynamically.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
