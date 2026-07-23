import SwiftUI
import AppKit

@main
struct UncoilApp: App {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var settings = SettingsStore()
    @StateObject private var theme = ThemeStore.shared
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    init() {
        LaunchConfig.shared.prepareEnvironment()
        TablerIcons.register()
        // Connect (or spawn) the runtime daemon early so reattach info is
        // ready before the first session view appears.
        // UI tests stay deterministic with in-process PTYs unless the run
        // opts in with -runtime (used for manual persistence verification).
        if !LaunchConfig.shared.isUITesting
            || ProcessInfo.processInfo.arguments.contains("-runtime") {
            RuntimeClient.shared.start()
        }
        // Window state restoration can come back as "zero windows" once a
        // value-presented WindowGroup exists; sessions are persisted by our
        // own stores, so native window restoration is disabled entirely.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        // Fully opt out of AppKit state restoration: with another instance
        // alive (Xcode runs, tests) the shared saved state restores zero
        // windows. Uncoil's own stores restore everything that matters.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        // Stale saved state (written before this default existed) can still
        // restore "zero windows" — clear it; our stores restore real state.
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
           let bundleID = Bundle.main.bundleIdentifier {
            let savedState = library
                .appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent("\(bundleID).savedState", isDirectory: true)
            try? FileManager.default.removeItem(at: savedState)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(projectStore)
                .environmentObject(sessionStore)
                .environmentObject(settings)
                .environmentObject(theme)
                .preferredColorScheme(theme.palette.isLight ? .light : .dark)
                .frame(minWidth: 940, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button(sidebarVisible ? "Kenar Çubuğunu Gizle" : "Kenar Çubuğunu Göster") {
                    sidebarVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)
            }
        }

        // Terminal-only popout: a session dragged/sent out of the main
        // window lives here; the PTY is shared via TerminalRegistry.
        WindowGroup("Oturum", id: "session-window", for: UUID.self) { $sessionID in
            if let sessionID {
                SessionPopoutWindow(sessionID: sessionID)
                    .environmentObject(projectStore)
                    .environmentObject(sessionStore)
                    .environmentObject(settings)
                    .environmentObject(theme)
                }
        }
        .windowStyle(.hiddenTitleBar)

        Window("Uncoil Ayarları", id: "settings") {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(projectStore)
                .environmentObject(theme)
                .preferredColorScheme(theme.palette.isLight ? .light : .dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
