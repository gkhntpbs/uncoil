import AppKit
import SwiftUI

/// The windows Uncoil has, named once.
///
/// The ids were bare strings at a dozen call sites — the app, the sidebar, the
/// palette, the menu-bar extra, a settings page, the app delegate — and two
/// places matched them by *substring* or by window title. Which meant that
/// which windows exist, and how to reach one, was knowledge duplicated across
/// six files, and that renaming or merging a window (folding Extensions into
/// the main window, say) touched every one of them.
///
/// A window is a case here; the scene declarations and the `openWindow` calls
/// both read it, so the two cannot drift apart.
enum AppWindow: String, CaseIterable, Identifiable {
    /// The project/session shell. Several may be open at once.
    case main
    /// One session on its own, popped out of a shell window.
    case session = "session-window"
    case settings
    case extensions

    var id: String { rawValue }

    /// Whether this window is something the shell opened *beside* itself.
    ///
    /// The command palette asks so it does not open over Settings or a popout;
    /// it used to ask by substring, which is a question about spelling rather
    /// than about the window.
    var isAuxiliary: Bool {
        switch self {
        case .main: false
        case .session, .settings, .extensions: true
        }
    }

    /// Which window an `NSWindow` belongs to, if it is one of ours.
    ///
    /// By scene id, never by title: the titles are localized, and matching on
    /// them is what made the palette open over Settings the moment the
    /// interface language stopped being English. A value-presented scene
    /// suffixes its id with the value, so the match is a prefix.
    static func of(_ window: NSWindow?) -> AppWindow? {
        guard let identifier = window?.identifier?.rawValue else { return nil }
        return allCases.first { identifier == $0.rawValue || identifier.hasPrefix("\($0.rawValue)-") }
    }
}

extension OpenWindowAction {
    func callAsFunction(_ window: AppWindow) {
        self(id: window.rawValue)
    }

    func callAsFunction(_ window: AppWindow, value: some Codable & Hashable) {
        self(id: window.rawValue, value: value)
    }
}
