import SwiftUI

/// The Extensions menu: opening the window on a given screen, and the handful of
/// actions worth reaching without opening it first.
struct ExtensionsMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Extensions") {
            Button("Open Extensions") { open(nil) }
                .keyboardShortcut("e", modifiers: [.command, .shift])

            Divider()

            ForEach(ExtensionsView.Section.allCases) { section in
                Button(section.title) { open(section) }
            }

            Divider()

            Button("Rescan") { open(.overview, action: .rediscover) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Run Health Check") { open(.overview, action: .healthCheck) }
            Button("Run Bumblebee Scan") { open(.security, action: .bumblebeeScan) }
        }
    }

    private func open(_ section: ExtensionsView.Section?, action: ExtensionsQuickAction? = nil) {
        Router.shared.go(to: .extensions(section: section, action: action))
        openWindow(.extensions)
    }
}
