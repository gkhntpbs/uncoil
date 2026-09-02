import Foundation

/// Who to ask what the newest version of an agent CLI is.
///
/// The question only has an answer inside the channel the tool was installed
/// from, and Uncoil used to ask npm about all of them. That is how a Homebrew
/// install came to advertise an update it could not deliver: `codex` was
/// installed as a cask at 0.152.0, npm had published 0.152.1, so Uncoil
/// offered an update — and `brew upgrade` had nothing newer to give, exited 0,
/// and left the version where it was. The button worked; the answer it was
/// working from came from somewhere else.
enum AgentVersionSource: Equatable {
    /// The npm registry, for a package this install genuinely came from.
    case npm(package: String)
    /// `brew outdated`, which reports against the taps this machine has.
    case homebrew(name: String)
    /// The tool answers the question itself, in a form Uncoil can read — run
    /// with these arguments, it prints JSON carrying the newest version.
    ///
    /// Only for a check that is both machine-readable *and* quick. Hermes has
    /// a `update --check` too, and it fetches a git repository to answer:
    /// half a minute, on every launch, for one row. That one stays
    /// `selfChecking`, where the question is asked by pressing the button.
    case selfReport(arguments: [String])
    /// Nobody Uncoil can ask. The tool ships its own updater and publishes no
    /// version list to read, so "is there an update" is a question only the
    /// tool itself can answer — by being run.
    case none
}

/// What Uncoil knows about whether an agent CLI has a newer version.
enum AgentUpdateAvailability: Equatable {
    /// Nothing has come back yet. Distinct from `upToDate`, which is a claim.
    case unchecked
    case notInstalled
    case upToDate(installed: String)
    case available(installed: String?, latest: String)
    /// Installed and updatable, but the version cannot be known in advance —
    /// the tool's own updater is the only thing that can say. The update is
    /// offered anyway: refusing to offer it would leave the four agents that
    /// update themselves with no button at all, which is what happened before.
    case selfChecking
    /// Installed, and Uncoil has no update command it is willing to run.
    case noUpdater(reason: String)

    /// Whether this counts towards the "updates waiting" badge.
    ///
    /// Only a known newer version does. A tool that can only be asked by
    /// running its updater is not evidence of anything, and a badge that
    /// counted those would show a number that never went down.
    var isPending: Bool {
        if case .available = self { return true }
        return false
    }

    /// Whether to offer the Update button.
    var isActionable: Bool {
        switch self {
        case .available, .selfChecking: true
        case .unchecked, .notInstalled, .upToDate, .noUpdater: false
        }
    }
}

enum AgentUpdateCheck {
    /// Where a version number for this install can honestly come from.
    static func versionSource(
        provider: AgentProvider,
        source: AgentInstallSource
    ) -> AgentVersionSource {
        switch source {
        case .homebrew(let formula, _):
            return formula.isEmpty ? .none : .homebrew(name: formula)

        case .npm, .volta:
            let package = AgentCLIInstall.npmPackage(for: provider)
            return package.isEmpty ? .none : .npm(package: package)

        case .nativeInstaller, .unknown:
            // Claude is the one exception, and it is a real one rather than a
            // convenience: Anthropic publishes the same release to npm and to
            // the installer that `claude update` uses, so the registry answers
            // for an install that did not come from it. The others — Grok,
            // Cursor, Hermes, OpenCode's own installer — either publish
            // nothing or publish a package that is a different distribution
            // with its own version line, and reading that would recreate
            // exactly the mismatch this type exists to prevent.
            if provider == .claude {
                let package = AgentCLIInstall.npmPackage(for: provider)
                return package.isEmpty ? .none : .npm(package: package)
            }
            // Grok publishes nothing Uncoil can read, but it will say so
            // itself: `grok update --check --json` answers with the version it
            // would install. Verified against the installed CLI's own help.
            if provider == .grok {
                return .selfReport(arguments: ["update", "--check", "--json"])
            }
            return .none
        }
    }

    /// The one place that decides what a row says and whether it offers a button.
    static func availability(
        installed: String?,
        latest: String?,
        plan: AgentUpdatePlan,
        versionSource: AgentVersionSource,
        isNewer: (String?, String?) -> Bool
    ) -> AgentUpdateAvailability {
        guard let installed else { return .notInstalled }
        if case .cannot(let reason) = plan { return .noUpdater(reason: reason) }
        guard versionSource != .none else { return .selfChecking }
        guard let latest else { return .unchecked }
        if isNewer(latest, installed) {
            return .available(installed: installed, latest: latest)
        }
        return .upToDate(installed: installed)
    }
}

// MARK: - Homebrew

enum HomebrewOutdated {
    /// `brew outdated --json=v2` → package name to the version Homebrew has.
    ///
    /// Formulae and casks are reported under separate keys and with the same
    /// shape, and both are folded into one table: which of the two a tool is
    /// matters for the upgrade command, not for the question of whether a
    /// newer version exists.
    static func parse(_ data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var latest: [String: String] = [:]
        for key in ["formulae", "casks"] {
            for entry in object[key] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String,
                      let current = entry["current_version"] as? String,
                      !name.isEmpty, !current.isEmpty
                else { continue }
                latest[name] = current
                // A tap-qualified name is what a third-party tap's package is
                // called when it shadows one in core, and it is the name the
                // upgrade has to use to be unambiguous.
                if let slash = name.lastIndex(of: "/") {
                    latest[String(name[name.index(after: slash)...])] = current
                }
            }
        }
        return latest
    }
}


/// A tool's own answer to "is there a newer version".
enum SelfReportedUpdate {
    /// Reads the newest version out of a JSON object the tool printed.
    ///
    /// Both spellings are accepted because there is no convention here — this
    /// is each vendor's own output, and the only thing the shape has to do is
    /// carry a version.
    static func latestVersion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["latestVersion", "latest_version", "latest"] {
            if let version = object[key] as? String, !version.isEmpty { return version }
        }
        return nil
    }
}
