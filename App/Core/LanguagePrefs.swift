import Foundation

/// The language Uncoil's own interface is drawn in.
///
/// `.system` follows macOS's preferred-language order, which is what a user who
/// never opens this setting expects. The explicit cases exist because a
/// developer's Mac is often set to English while they would rather read Uncoil
/// in Turkish — or the reverse.
enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case turkish

    var id: String { rawValue }

    /// BCP-47 identifier, or nil when the system order should be used as-is.
    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .turkish: "tr"
        }
    }

    /// Shown in its own language, the way macOS lists languages: a user looking
    /// for Turkish looks for "Türkçe", not for whatever "Turkish" is in the
    /// language they are currently stuck in.
    var displayName: String {
        switch self {
        case .system: String(localized: "Match system")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }
}

/// The language Uncoil writes in when it composes a prompt for an agent —
/// task dispatch, orchestration, run repair, session grouping.
///
/// Deliberately separate from ``InterfaceLanguage``: reading the app in Turkish
/// and having agents answer in English is a normal combination, because the
/// code, the commit messages and the libraries are English anyway.
enum AgentLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Whatever the interface resolves to.
    case followInterface
    case english
    case turkish

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .followInterface: String(localized: "Match interface language")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }
}

/// A language a prompt can actually be written in — the resolved form of
/// ``AgentLanguage``, with `.followInterface` already collapsed.
enum PromptLanguage: String, Sendable {
    case english
    case turkish

    /// The endonym, which is what an LLM responds to most reliably: naming the
    /// language in itself leaves no room for the model to answer *about* the
    /// language instead of *in* it.
    var endonym: String {
        switch self {
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    /// A single line appended to generated prompts.
    ///
    /// Prompt templates are authored in English and stay that way; only this
    /// directive changes. Maintaining one template per language would double
    /// the surface that can drift, and a model follows an explicit instruction
    /// about output language more reliably than it mirrors the input's.
    /// English needs no directive — the prompt is already English.
    var directive: String? {
        switch self {
        case .english: nil
        case .turkish: "Reply in \(endonym)."
        }
    }
}

#if canImport(AppKit)
import AppKit

enum AppRelaunch {
    /// Quits and starts a fresh copy of the running bundle.
    ///
    /// `open -n` is done through a detached `Process` rather than
    /// `NSWorkspace.openApplication` on purpose: the new instance must not be
    /// parented to the one that is about to die, or macOS reuses the dying
    /// process and the relaunch silently becomes a no-op.
    @MainActor
    static func now() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
#endif

/// Persisted language selection.
struct LanguagePrefs: Codable, Equatable, Sendable {
    var interface: InterfaceLanguage = .system
    var agent: AgentLanguage = .followInterface

    init(interface: InterfaceLanguage = .system, agent: AgentLanguage = .followInterface) {
        self.interface = interface
        self.agent = agent
    }

    /// True when the running process is not yet showing the chosen language.
    ///
    /// The interface language is applied by writing `AppleLanguages`, which
    /// `Bundle` reads once at launch. Switching live was tried and rejected:
    /// SwiftUI literals follow `\.locale` immediately, but `String(localized:)`
    /// — every notification, menu-bar label and model-owned string — resolves
    /// against the process locale, so the window ended up half translated. One
    /// relaunch, everything in one language.
    func needsRelaunch(currentLanguages: [String] = Bundle.main.preferredLocalizations) -> Bool {
        guard let chosen = interface.localeIdentifier else { return false }
        return currentLanguages.first.map { $0 != chosen } ?? true
    }

    /// The interface language as a prompt language, resolving `.system` against
    /// the given preferred-language list. Anything that is not Turkish resolves
    /// to English, because English is the only other language Uncoil ships.
    func resolvedInterface(preferredLanguages: [String] = Locale.preferredLanguages) -> PromptLanguage {
        switch interface {
        case .english: return .english
        case .turkish: return .turkish
        case .system:
            let code = preferredLanguages.first.map { Locale(identifier: $0) }?.language.languageCode?.identifier
            return code == "tr" ? .turkish : .english
        }
    }

    /// The language Uncoil composes agent prompts in.
    func resolvedAgent(preferredLanguages: [String] = Locale.preferredLanguages) -> PromptLanguage {
        switch agent {
        case .english: return .english
        case .turkish: return .turkish
        case .followInterface: return resolvedInterface(preferredLanguages: preferredLanguages)
        }
    }
}
