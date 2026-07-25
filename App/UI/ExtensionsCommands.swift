import SwiftUI

/// What the Extensions menu asks the Extensions window to do.
///
/// The window owns the registry and the scan coordinator, so a menu item cannot
/// act on them directly. It leaves a request here instead; the window picks it up
/// when it appears (or immediately, when it is already open), which also means a
/// quick action works whether or not the window was open when it was chosen.
@MainActor
final class ExtensionsCommandBus: ObservableObject {
    enum QuickAction: String, Identifiable, Equatable {
        case rediscover
        case healthCheck
        case bumblebeeScan

        var id: String { rawValue }
    }

    static let shared = ExtensionsCommandBus()

    /// The section to show. Consumed by the window; nil means "leave it alone".
    @Published var route: ExtensionsView.Section?
    /// A one-shot request, cleared by the window once it has run it.
    @Published var request: QuickAction?

    private init() {}

    func open(_ section: ExtensionsView.Section?, action: QuickAction? = nil) {
        if let section { route = section }
        if let action { request = action }
    }
}

/// The Extensions menu: opening the window on a given screen, and the handful of
/// actions worth reaching without opening it first.
struct ExtensionsMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private var bus: ExtensionsCommandBus { .shared }

    var body: some Commands {
        CommandMenu("Extensions") {
            Button("Extensions'ı Aç") { open(nil) }
                .keyboardShortcut("e", modifiers: [.command, .shift])

            Divider()

            ForEach(ExtensionsView.Section.allCases) { section in
                Button(section.title) { open(section) }
            }

            Divider()

            Button("Yeniden Tara") { open(.overview, action: .rediscover) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Health Check Çalıştır") { open(.overview, action: .healthCheck) }
            Button("Bumblebee Taraması Çalıştır") { open(.security, action: .bumblebeeScan) }
        }
    }

    private func open(_ section: ExtensionsView.Section?, action: ExtensionsCommandBus.QuickAction? = nil) {
        bus.open(section, action: action)
        openWindow(id: "extensions")
    }
}
