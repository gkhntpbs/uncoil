import SwiftUI

@main
struct UncoilApp: App {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(projectStore)
                .environmentObject(sessionStore)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Project…") {
                    NotificationCenter.default.post(name: .uncoilAddProject, object: nil)
                }
                .keyboardShortcut("O", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let uncoilAddProject = Notification.Name("uncoil.addProject")
}
