import Foundation

/// Human-readable metadata for every control-plane capability grant key, so the
/// Settings → İzinler pane can present grants as labelled, grouped toggles. The
/// catalog is total: `entry(for:)` returns non-nil for every key in
/// `PolicyEngine.defaultGrants ∪ PolicyEngine.optionalGrants` (asserted by a
/// unit test). Pure data — no view dependencies — so it stays testable.
enum CapabilityCatalog {
    /// Capability domains, in display order.
    enum Domain: String, CaseIterable, Identifiable {
        case projects, worktrees, sessions, browser, computer, artifacts
        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: "Projeler"
            case .worktrees: "Worktree"
            case .sessions: "Oturumlar"
            case .browser: "Tarayıcı"
            case .computer: "Bilgisayar"
            case .artifacts: "Artifact"
            }
        }

        var iconName: String {
            switch self {
            case .projects: "folders"
            case .worktrees: "git-branch"
            case .sessions: "messages"
            case .browser: "world"
            case .computer: "device-desktop"
            case .artifacts: "file-text"
            }
        }
    }

    struct Entry: Identifiable {
        let key: String
        let domain: Domain
        let label: String
        let detail: String
        /// Elevated-risk grant: control that reaches beyond the agent's own
        /// sandbox (foreground control, cross-project, other sessions, personal
        /// browser profile). Surfaced with a warning hint in the UI.
        let risky: Bool

        var id: String { key }
    }

    /// Every grant key the policy engine understands, with Turkish labels.
    static let all: [Entry] = [
        .init(key: "projects.read", domain: .projects,
              label: "Projeleri oku",
              detail: "Proje listesi ve meta verilerini görür.", risky: false),

        .init(key: "worktrees.read", domain: .worktrees,
              label: "Worktree'leri oku",
              detail: "Mevcut worktree'leri listeler.", risky: false),
        .init(key: "worktrees.create", domain: .worktrees,
              label: "Worktree oluştur",
              detail: "Yeni git worktree açabilir.", risky: false),

        .init(key: "sessions.read", domain: .sessions,
              label: "Oturumları oku",
              detail: "Aynı projedeki oturumları görür.", risky: false),
        .init(key: "sessions.read_all", domain: .sessions,
              label: "Tüm oturumları oku",
              detail: "Diğer projelerdeki oturumları da görür.", risky: true),
        .init(key: "sessions.control_children", domain: .sessions,
              label: "Alt oturumları yönet",
              detail: "Kendi başlattığı çocuk oturumlara girdi gönderir/kapatır.", risky: false),
        .init(key: "sessions.create_children", domain: .sessions,
              label: "Alt oturum oluştur",
              detail: "Preset'lerle yeni çocuk oturum başlatabilir.", risky: false),
        .init(key: "sessions.cross_project", domain: .sessions,
              label: "Projeler arası oturum",
              detail: "Farklı projelerdeki oturumlarla etkileşebilir.", risky: true),

        .init(key: "browser.use", domain: .browser,
              label: "Tarayıcı kullan",
              detail: "Yönetilen tarayıcıyı sürebilir.", risky: false),
        .init(key: "browser.persistent_state", domain: .browser,
              label: "Kalıcı tarayıcı profili",
              detail: "Oturum açık kişisel tarayıcı profilini kullanır.", risky: true),

        .init(key: "computer.inspect", domain: .computer,
              label: "Ekranı incele",
              detail: "Ekran görüntüsü alır, arayüzü okur.", risky: false),
        .init(key: "computer.background_control", domain: .computer,
              label: "Arka planda kontrol",
              detail: "Odaktaki uygulamayı çalmadan kontrol eder.", risky: true),
        .init(key: "computer.foreground_control", domain: .computer,
              label: "Ön planda kontrol",
              detail: "Fare/klavyeni ele alır — tam kontrol.", risky: true),

        .init(key: "artifacts.read", domain: .artifacts,
              label: "Artifact oku",
              detail: "Oturum artefaktlarını okur.", risky: false),
        .init(key: "artifacts.write", domain: .artifacts,
              label: "Artifact yaz",
              detail: "Oturum artefaktları oluşturur/günceller.", risky: false),
    ]

    private static let byKey: [String: Entry] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    static func entry(for key: String) -> Entry? { byKey[key] }

    /// Entries grouped by domain, in domain display order, each preserving the
    /// declared order of `all`.
    static func grouped() -> [(domain: Domain, entries: [Entry])] {
        Domain.allCases.compactMap { domain in
            let entries = all.filter { $0.domain == domain }
            return entries.isEmpty ? nil : (domain, entries)
        }
    }

    /// The full set of keys a session can be granted (default ∪ optional).
    static var allKeys: Set<String> {
        PolicyEngine.defaultGrants.union(PolicyEngine.optionalGrants)
    }
}
