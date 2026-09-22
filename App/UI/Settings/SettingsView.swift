import SwiftUI

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

    /// The six things settings are actually about, plus About.
    ///
    /// There were eight, and four of them held a single page — a category of
    /// one is a heading pretending to be a group, and it pushed the pages that
    /// really belonged together apart. Pages also sat where they had been
    /// written rather than where they are looked for: Quick Launch is a strip
    /// in the interface and was filed under Agents, and Status Tracking writes
    /// into Claude's own `settings.json`, which makes it an integration with a
    /// CLI rather than a privacy setting.
    ///
    /// Raw values are not load-bearing here — deep links address *panes* — so
    /// a category can be renamed without breaking anything.
    enum Category: String, CaseIterable, Identifiable {
        case general
        case agents
        case notifications
        case appearance
        case uncoil
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .agents: String(localized: "Agents")
            case .notifications: String(localized: "Notifications")
            case .appearance: String(localized: "Appearance")
            case .uncoil: "Uncoil"
            case .about: String(localized: "About")
            }
        }

    }

    /// One detail page.
    ///
    /// Not `CaseIterable`: the Agents category has one page per agent, so the
    /// list is partly derived from what is installed on this Mac. `id` is the
    /// stable address — the command palette, deep links and the UI tests use
    /// it — and an agent page's is `agent.<provider>`.
    enum Pane: Hashable, Identifiable {
        case general
        case input

        /// Which agent CLIs exist and how deeply each is connected. The pages
        /// below configure one agent; this one is about the set of them, and it
        /// is also the only place to reach an agent that is not installed.
        case agents
        /// Everything about one agent: its logins, what it does on its own,
        /// and the CLI Uncoil runs.
        case agent(AgentProvider)
        case presets
        case blueprints

        case notifications
        case notificationEvents
        case reminders
        case quietHours

        case theme
        case menuBar
        case launcher

        case permissions
        case mcp
        case hooks
        case drivers
        case github
        case privacyData

        case about

        var id: String {
            switch self {
            case .general: "general"
            case .input: "input"
            case .agents: "agents"
            case .agent(let provider): "agent.\(provider.rawValue)"
            case .presets: "presets"
            case .blueprints: "blueprints"
            case .notifications: "notifications"
            case .notificationEvents: "notificationEvents"
            case .reminders: "reminders"
            case .quietHours: "quietHours"
            case .theme: "theme"
            case .menuBar: "menuBar"
            case .launcher: "launcher"
            case .permissions: "permissions"
            case .mcp: "mcp"
            case .hooks: "hooks"
            case .drivers: "drivers"
            case .github: "github"
            case .privacyData: "privacyData"
            case .about: "about"
            }
        }

        /// Everything that does not depend on what is installed. Reading order
        /// within a category is the order here.
        static let fixed: [Pane] = [
            .general, .input,
            .agents, .presets, .blueprints,
            .notifications, .notificationEvents, .reminders, .quietHours,
            .theme, .menuBar, .launcher,
            .permissions, .mcp, .hooks, .drivers, .github, .privacyData,
            .about,
        ]

        /// The source list. Agent pages are deliberately absent: one row per
        /// agent would grow the sidebar with every CLI installed and restate
        /// the list the Agents page already shows. They are reached by opening
        /// a row there, and the sidebar keeps Agents selected while one is open.
        static var sidebar: [Pane] { fixed }

        /// What the command palette and the search box may offer — the source
        /// list plus every agent's page, installed or not: a user looking for
        /// Codex should find its page and read that it is missing, rather than
        /// find nothing and conclude Uncoil has no such setting.
        static let searchable: [Pane] = fixed + AgentProvider.agents.map(Pane.agent)

        /// Which row in the source list is the home of this page. An agent page
        /// has no row of its own, so it keeps its parent lit.
        var sidebarPane: Pane {
            if case .agent = self { return .agents }
            return self
        }

        var category: Category {
            switch self {
            case .general, .input: .general
            case .agents, .agent, .presets, .blueprints: .agents
            case .notifications, .notificationEvents, .reminders, .quietHours: .notifications
            // How Uncoil looks and what it puts in front of you.
            case .theme, .menuBar, .launcher: .appearance
            // Uncoil's own machinery: what it lets agents do, how it talks to
            // them, what it connects to, and what it keeps.
            //
            // "Security and Data" and "Integrations" were dissolved into this
            // rather than left beside it. Splitting them three ways would have
            // put Permissions and the control plane that enforces them under
            // different headings, and left the two survivors holding one page
            // each — the defect this tree was reorganised to remove.
            case .permissions, .mcp, .hooks, .drivers, .github, .privacyData: .uncoil
            case .about: .about
            }
        }

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .input: String(localized: "Keyboard and Input")
            case .agents: String(localized: "Installed Agents")
            case .agent(let provider): provider.descriptor.displayName
            case .presets: String(localized: "Session Presets")
            case .blueprints: String(localized: "Blueprints")
            case .launcher: String(localized: "Quick Launch")
            case .notifications: String(localized: "General")
            case .notificationEvents: String(localized: "Events")
            case .reminders: String(localized: "Reminders")
            case .quietHours: String(localized: "Quiet Hours")
            case .menuBar: String(localized: "Menu Bar")
            case .theme: String(localized: "Theme and Colours")
            case .permissions: String(localized: "Permissions")
            case .privacyData: String(localized: "Data and Transcripts")
            case .hooks: String(localized: "Agent Status Hooks")
            case .github: "GitHub"
            case .drivers: String(localized: "Drivers")
            case .mcp: String(localized: "Uncoil MCP")
            case .about: String(localized: "About")
            }
        }

        var symbolName: String {
            switch self {
            case .general: "gearshape"
            case .input: "keyboard"
            case .agents: "point.3.connected.trianglepath.dotted"
            case .agent: "person.2"
            case .presets: "square.stack.3d.up"
            case .blueprints: "square.grid.2x2"
            case .launcher: "bolt"
            case .notifications: "bell"
            case .notificationEvents: "list.bullet.rectangle"
            case .reminders: "alarm"
            case .quietHours: "moon"
            case .menuBar: "menubar.rectangle"
            case .theme: "paintpalette"
            case .permissions: "lock.shield"
            case .privacyData: "externaldrive.badge.person.crop"
            case .hooks: "point.3.connected.trianglepath.dotted"
            case .github: "chevron.left.forwardslash.chevron.right"
            case .drivers: "puzzlepiece.extension"
            case .mcp: "point.3.connected.trianglepath.dotted"
            case .about: "info.circle"
            }
        }

        /// Search terms (Turkish + English) matched by the filter box. They name
        /// the *settings inside* the page, not the page — searching "sessiz"
        /// should find the sound picker even though no page is called that.
        var keywords: String {
            switch self {
            case .general:
                "varsayılan default editör editor agent dil language kapanış quit çıkış kısayol hotkey komut paleti palette"
            case .input: "klavye keyboard shift enter newline satır line yapıştır paste görsel image ⌘v pano clipboard giriş input option meta alt değiştirici modifier"
            case .agents: "agent ajan bağla connect hook kanca algıla detect tara scan kurulu installed seviye level konum location bul locate yol path kurulum install bulunamadı not found"
            // An agent page holds what four matrices used to, so it answers to
            // all of their terms — plus the agent's own name, which is what a
            // user actually types.
            case .agent(let provider):
                "\(provider.descriptor.displayName) \(provider.descriptor.fullName) hesap account login giriş profil profile e-posta email cli güncelle update sürüm version brew npm kurulum install parametre argüman argument model flag bayrak davranış behavior mod mode auto plan onay approval yetki varsayılan default konum location yol path"
            case .presets: "preset alt agent child yetki capability prompt şablon template"
            case .blueprints: "blueprint şema plan iskelet scaffold kurulum setup yeni proje new project prompt şablon template klasör yapısı structure"
            case .launcher: "kısayol shortcut hızlı quick launch başlat strip şerit sırala reorder sürükle drag terminal agent"
            case .notifications: "bildirim notification izin permission ses sound gruplama grouping teslimat delivery arka plan background"
            case .notificationEvents: "olay event izin permission girdi input tur tamamlandı turn hata error sorun görev task merge öncelik priority ses sound"
            case .reminders: "hatırlatma reminder tekrar repeat aralık interval ikinci kez bekliyor waiting"
            case .quietHours: "sessiz saat quiet hours rahatsız etme do not disturb gece night odak focus"
            case .menuBar: "menü bar menubar ikon icon simge sayaç counter status durum çubuğu mark"
            case .theme: "tema theme renk color açık koyu light dark terminal palet palette"
            case .permissions: "izin permission mcp grant onay approval agent kontrol control computer use browser"
            case .privacyData: "transcript kayıt saklama retention veri data gizlilik privacy sil temizle delete clear"
            case .hooks: "hook durum status izleme watching kanca claude settings.json"
            case .github: "github token pr pull request giriş login sign in"
            case .drivers: "sürücü driver agent-browser cua computer use kurulum install"
            case .mcp: "mcp control plane kontrol düzlemi araç tool uncoil_projects sunucu server soket socket kurulum install yapılandırma configure"
            case .about: "hakkında about sürüm version veri klasörü data folder debug bundle kaldır uninstall"
            }
        }

        var searchText: String { "\(title) \(category.title) \(keywords)".lowercased() }

        /// Deep links written before the pane tree was reorganised.
        ///
        /// The four cross-agent matrices — accounts, CLI tools, run parameters,
        /// working mode — no longer exist as pages. A link to one cannot name
        /// which agent was meant, so it lands on the Agents page, which lists
        /// them all and is one click from every setting the matrix held.
        static func resolve(_ raw: String) -> Pane? {
            if let match = searchable.first(where: { $0.id == raw }) { return match }
            switch raw {
            case "installedAgents": return .agents
            case "accounts", "cliTools", "launchArgs", "agentBehavior": return .agents
            // A project's own notification settings moved beside the
            // project, into its settings sheet; the deep link lands on the
            // notification defaults they inherit from.
            case "projectNotifications": return .notifications
            case "defaults": return .general
            case "notificationSounds": return .notifications
            case "transcripts": return .privacyData
            // The keyboard and paste settings moved off the agent page.
            case "keyboard", "shiftEnter", "imagePaste", "optionAsMeta": return .input
            default: return nil
            }
        }
    }

    private func panes(in category: Category) -> [Pane] {
        Pane.sidebar.filter { $0.category == category }
    }

    /// The sidebar selects the page's home row, not the page: an agent detail
    /// page keeps Agents lit rather than clearing the selection, which would
    /// leave the window looking as though nothing were open.
    private var sidebarSelection: Binding<Pane?> {
        Binding(get: { pane.sidebarPane }, set: { if let new = $0 { pane = new } })
    }

    private var matches: [Pane] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return Pane.searchable.filter { $0.searchText.contains(query) }
    }

    private var isSearching: Bool { !matches.isEmpty || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// See the `.id` on the detail pane for why this exists and why the Theme
    /// pane is the exception.
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
                // Scoped to the detail pane rather than to the whole split
                // view. `.id` rebuilds what it is attached to, and attached to
                // the window it rebuilt the sidebar as well — which threw the
                // source list back to the top every time the theme changed,
                // right when the user was in Theme and Colours looking at it.
                // The sidebar does not need it: it is drawn by this view's own
                // body, which re-evaluates when `theme` publishes.
                .id(paletteIdentity)
        }
        .navigationTitle(pane.title)
        .navigationSubtitle(pane.category.title)
        .searchable(text: $search, placement: .sidebar, prompt: String(localized: "Search settings"))
        .frame(minWidth: 700, idealWidth: 840, minHeight: 460, idealHeight: 620)
        .tint(Theme.highlight)
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.container")
        .onAppear { applyRequestedPane() }
        .onReceive(Router.shared.$requestedPane) { _ in applyRequestedPane() }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: sidebarSelection) {
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
                        ForEach(panes(in: category)) { paneRow($0, showsCategory: false) }
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
        .accessibilityIdentifier("settings.pane.\(candidate.id)")
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettingsPage()
        case .input: InputSettingsPage()
        case .agents: AgentsSettingsPage(open: { pane = .agent($0) })
        case .agent(let provider):
            AgentSettingsPage(provider: provider, back: { pane = .agents })
        case .presets: SessionPresetsSettingsPage()
        case .blueprints: BlueprintsSettingsPage()
        case .launcher: LauncherSettingsPage()
        case .notifications: NotificationGeneralPage()
        case .notificationEvents: NotificationEventsPage()
        case .reminders: NotificationRemindersPage()
        case .quietHours: NotificationQuietHoursPage()
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
        case .mcp: McpSettingsPage()
        case .about: AboutSettingsPage()
        }
    }

    private func applyRequestedPane() {
        guard let raw = Router.shared.requestedPane,
              let requested = Pane.resolve(raw) else { return }
        pane = requested
        search = ""
        _ = Router.shared.takePane()
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
