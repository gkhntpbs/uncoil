import SwiftUI

/// Cross-window channel so the command palette can deep-link to a settings pane.
@MainActor
final class SettingsRoute: ObservableObject {
    static let shared = SettingsRoute()
    @Published var requestedPane: String?
}

/// Settings, built on the platform's own furniture — a source list of
/// categories, `Form(.grouped)` detail pages, system controls and system type —
/// wearing Uncoil's palette.
///
/// The structure is AppKit's because that is what a user arrives expecting from
/// every other app they own; the colours are ours because a settings window that
/// looks like a different application than the one it configures is jarring. So
/// the layout, spacing and control behaviour are stock, and the surfaces,
/// accent, text and status colours come from `ThemeStore`.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var theme: ThemeStore

    @State private var pane: Pane = .general
    @State private var search = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // MARK: - Structure

    enum Category: String, CaseIterable, Identifiable {
        case general
        case agents
        case notifications
        case menuBar
        case appearance
        case privacy
        case integrations
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .agents: String(localized: "Agents")
            case .notifications: String(localized: "Notifications")
            case .menuBar: String(localized: "Menu Bar")
            case .appearance: String(localized: "Appearance")
            case .privacy: String(localized: "Privacy and Permissions")
            case .integrations: String(localized: "Integrations")
            case .about: String(localized: "About")
            }
        }

        var panes: [Pane] { Pane.allCases.filter { $0.category == self } }
    }

    /// One detail page. Raw values are stable: the command palette and the UI
    /// tests address panes by them.
    enum Pane: String, CaseIterable, Identifiable {
        case general
        case accounts
        case cliTools
        case launchArgs
        case agentBehavior
        case presets
        case notifications
        case notificationEvents
        case reminders
        case quietHours
        case projectNotifications
        case menuBar
        case theme
        case permissions
        case privacyData
        case hooks
        case github
        case drivers
        case about

        var id: String { rawValue }

        var category: Category {
            switch self {
            case .general: .general
            case .accounts, .cliTools, .launchArgs, .agentBehavior, .presets: .agents
            case .notifications, .notificationEvents, .reminders, .quietHours,
                 .projectNotifications: .notifications
            case .menuBar: .menuBar
            case .theme: .appearance
            case .permissions, .privacyData, .hooks: .privacy
            case .github, .drivers: .integrations
            case .about: .about
            }
        }

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .accounts: String(localized: "Accounts")
            case .cliTools: String(localized: "CLI Tools")
            case .launchArgs: String(localized: "Run Parameters")
            case .agentBehavior: String(localized: "Mode and Keyboard")
            case .presets: String(localized: "Session Presets")
            case .notifications: String(localized: "General")
            case .notificationEvents: String(localized: "Events")
            case .reminders: String(localized: "Reminders")
            case .quietHours: String(localized: "Quiet Hours")
            case .projectNotifications: String(localized: "Per Project")
            case .menuBar: String(localized: "Menu Bar")
            case .theme: String(localized: "Theme and Colours")
            case .permissions: String(localized: "Permissions")
            case .privacyData: String(localized: "Data and Transcripts")
            case .hooks: String(localized: "Status Tracking")
            case .github: "GitHub"
            case .drivers: String(localized: "Drivers")
            case .about: String(localized: "About")
            }
        }

        var symbolName: String {
            switch self {
            case .general: "gearshape"
            case .accounts: "person.2"
            case .cliTools: "terminal"
            case .launchArgs: "command"
            case .agentBehavior: "keyboard"
            case .presets: "square.stack.3d.up"
            case .notifications: "bell"
            case .notificationEvents: "list.bullet.rectangle"
            case .reminders: "alarm"
            case .quietHours: "moon"
            case .projectNotifications: "folder.badge.gearshape"
            case .menuBar: "menubar.rectangle"
            case .theme: "paintpalette"
            case .permissions: "lock.shield"
            case .privacyData: "externaldrive.badge.person.crop"
            case .hooks: "point.3.connected.trianglepath.dotted"
            case .github: "chevron.left.forwardslash.chevron.right"
            case .drivers: "puzzlepiece.extension"
            case .about: "info.circle"
            }
        }

        /// Search terms (Turkish + English) matched by the filter box. They name
        /// the *settings inside* the page, not the page — searching "sessiz"
        /// should find the sound picker even though no page is called that.
        var keywords: String {
            switch self {
            case .general:
                "varsayılan default editör editor agent kapanış quit çıkış kısayol hotkey komut paleti palette"
            case .accounts: "hesap account claude codex login giriş profil profile e-posta email"
            case .cliTools: "cli güncelle update sürüm version brew npm kurulum install"
            case .launchArgs: "parametre argüman argument model flag bayrak"
            case .agentBehavior: "agent davranış behavior mod mode auto plan shift enter newline satır klavye keyboard behaviour line"
            case .presets: "preset alt agent child yetki capability prompt şablon template"
            case .notifications: "bildirim notification izin permission ses sound gruplama grouping teslimat delivery arka plan background"
            case .notificationEvents: "olay event izin permission girdi input tur tamamlandı turn hata error sorun görev task merge öncelik priority ses sound"
            case .reminders: "hatırlatma reminder tekrar repeat aralık interval ikinci kez bekliyor waiting"
            case .quietHours: "sessiz saat quiet hours rahatsız etme do not disturb gece night odak focus"
            case .projectNotifications: "proje project bazında override bildirim notification"
            case .menuBar: "menü bar menubar ikon icon simge sayaç counter status durum çubuğu mark"
            case .theme: "tema theme renk color açık koyu light dark terminal palet palette"
            case .permissions: "izin permission mcp grant onay approval agent kontrol control computer use browser"
            case .privacyData: "transcript kayıt saklama retention veri data gizlilik privacy sil temizle delete clear"
            case .hooks: "hook durum status izleme watching kanca claude settings.json"
            case .github: "github token pr pull request giriş login sign in"
            case .drivers: "sürücü driver agent-browser cua computer use kurulum install"
            case .about: "hakkında about sürüm version veri klasörü data folder debug bundle kaldır uninstall"
            }
        }

        var searchText: String { "\(title) \(category.title) \(keywords)".lowercased() }

        /// Deep links written before the pane tree was reorganised.
        static func resolve(_ raw: String) -> Pane? {
            if let exact = Pane(rawValue: raw) { return exact }
            switch raw {
            case "defaults": return .general
            case "notificationSounds": return .notifications
            case "transcripts": return .privacyData
            default: return nil
            }
        }
    }

    private var matches: [Pane] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return Pane.allCases.filter { $0.searchText.contains(query) }
    }

    private var isSearching: Bool { !matches.isEmpty || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// See the `.id` on the body for why this exists and why the Tema pane is
    /// the exception.
    private var paletteIdentity: AnyHashable {
        pane == .theme ? AnyHashable(theme.palette.isLight) : AnyHashable(theme.palette)
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 186, ideal: 208, max: 260)
        } detail: {
            detail
        }
        .navigationTitle(pane.title)
        .navigationSubtitle(pane.category.title)
        .searchable(text: $search, placement: .sidebar, prompt: String(localized: "Search settings"))
        .frame(minWidth: 700, idealWidth: 840, minHeight: 460, idealHeight: 620)
        .tint(Theme.highlight)
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        // `Theme.*` are static reads SwiftUI cannot track, so a palette edit
        // has to re-identify the view to reach them. Everywhere except the Tema
        // pane that key is the whole palette; there it is the mode alone,
        // because re-identifying while a colour picker is open tears the picker
        // out from under the drag.
        .id(paletteIdentity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.container")
        .onAppear { applyRequestedPane() }
        .onReceive(SettingsRoute.shared.$requestedPane) { _ in applyRequestedPane() }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $pane) {
            if isSearching {
                Section("Results") {
                    if matches.isEmpty {
                        Text("No matching setting")
                            .foregroundStyle(Theme.textFaint)
                    }
                    ForEach(matches) { paneRow($0, showsCategory: true) }
                }
            } else {
                ForEach(Category.allCases) { category in
                    Section(category.title) {
                        ForEach(category.panes) { paneRow($0, showsCategory: false) }
                    }
                }
            }
        }
        .uncoilScrollers()
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
    }

    private func paneRow(_ candidate: Pane, showsCategory: Bool) -> some View {
        NavigationLink(value: candidate) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.title)
                    if showsCategory {
                        Text(candidate.category.title)
                            .font(.caption2)
                            .foregroundStyle(Theme.textFaint)
                    }
                }
            } icon: {
                Image(systemName: candidate.symbolName)
                    .foregroundStyle(pane == candidate ? Theme.highlight : Theme.textDim)
            }
        }
        .tag(candidate)
        .accessibilityIdentifier("settings.pane.\(candidate.rawValue)")
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettingsPage()
        case .accounts: AccountsSettingsPage()
        case .cliTools: CLIToolsSettingsPage()
        case .launchArgs: LaunchArgumentsSettingsPage()
        case .agentBehavior: AgentBehaviorSettingsPage()
        case .presets: SessionPresetsSettingsPage()
        case .notifications: NotificationGeneralPage()
        case .notificationEvents: NotificationEventsPage()
        case .reminders: NotificationRemindersPage()
        case .quietHours: NotificationQuietHoursPage()
        case .projectNotifications: ProjectNotificationsPage()
        case .menuBar: MenuBarSettingsPage()
        case .theme: AppearanceSettingsPage()
        case .permissions:
            if let service = sessionStore.permissionService {
                PermissionsSettingsPage(service: service)
            } else {
                SettingsUnavailablePage(
                    symbol: "lock.slash",
                    title: String(localized: "Control plane not running"),
                    detail: String(localized: "No permission request arrives while the MCP control plane is off.")
                )
            }
        case .privacyData: PrivacyDataSettingsPage()
        case .hooks: HooksSettingsPage()
        case .github: GitHubSettingsPage()
        case .drivers: DriversSettingsPage()
        case .about: AboutSettingsPage()
        }
    }

    private func applyRequestedPane() {
        guard let raw = SettingsRoute.shared.requestedPane,
              let requested = Pane.resolve(raw) else { return }
        pane = requested
        search = ""
        SettingsRoute.shared.requestedPane = nil
    }
}

/// Stand-in for a page whose backing service is not running.
struct SettingsUnavailablePage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
    }
}
