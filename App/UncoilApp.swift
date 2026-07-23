import SwiftUI
import AppKit

@main
struct UncoilApp: App {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var settings = SettingsStore()
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    init() {
        LaunchConfig.shared.prepareEnvironment()
        TablerIcons.register()
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(projectStore)
                .environmentObject(sessionStore)
                .environmentObject(settings)
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

        Window("Uncoil Ayarları", id: "settings") {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(projectStore)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
