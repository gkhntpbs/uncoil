import SwiftUI
import AppKit

@main
struct UncoilApp: App {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var settings = SettingsStore()

    init() {
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

        Window("Uncoil Ayarları", id: "settings") {
            SettingsView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
