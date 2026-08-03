import Foundation

/// How an agent CLI got onto this machine, and therefore how it is updated.
///
/// The old version of this asked three substring questions — Homebrew's
/// prefix, `node_modules`, and Claude's `.local/bin` — and called everything
/// else unknown. That missed the most common way a Node CLI is installed on a
/// Mac: through a version manager. `~/.nvm/versions/node/v24.1.0/bin/gemini`
/// contains none of those strings, so it read as unknown, and an unknown
/// install had no update command at all.
///
/// The reliable question is not "where is the launcher" but "what does it
/// resolve to". A global npm package always lands under `lib/node_modules`
/// whoever manages the Node it belongs to, so following the symlink answers
/// for nvm, fnm, asdf, `n` and a plain install at once — and gives back the
/// prefix, which is the part that matters.
enum AgentInstallSource: Equatable {
    /// Formula or cask name, which is not always the command's name.
    case homebrew(formula: String)
    /// A global npm package. `prefix` is the Node installation that owns it —
    /// `<prefix>/bin/npm` — when it could be worked out.
    case npm(prefix: String?)
    /// Volta manages its own shims; `npm install -g` does not reach them.
    case volta
    /// Claude's own installer, which updates itself.
    case nativeInstaller
    case unknown

    var label: String {
        switch self {
        case .homebrew: String(localized: "Homebrew")
        case .npm: String(localized: "npm")
        case .volta: String(localized: "Volta")
        case .nativeInstaller: String(localized: "built-in updater")
        case .unknown: String(localized: "unknown")
        }
    }
}

enum AgentCLIInstall {
    /// Homebrew's name for a tool, which is not the command's name for two of
    /// the three. `brew upgrade gemini` and `brew upgrade claude` are both
    /// "No available formula", which is what deriving the name from the
    /// provider's own raw value produced.
    static func brewFormula(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: "claude-code"
        case .codex: "codex"
        case .gemini: "gemini-cli"
        case .terminal: ""
        }
    }

    static func npmPackage(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: "@anthropic-ai/claude-code"
        case .codex: "@openai/codex"
        case .gemini: "@google/gemini-cli"
        case .terminal: ""
        }
    }

    /// Where a global npm package's Node lives, read out of the package path.
    ///
    /// `/…/v24.1.0/lib/node_modules/@google/gemini-cli/…` → `/…/v24.1.0`, so
    /// the update can run *that* Node's npm. Running whichever `npm` the login
    /// shell happens to resolve is how an update reports success and changes
    /// nothing: it installs into a different Node, and the binary on `PATH`
    /// stays exactly as old as it was.
    static func npmPrefix(fromPackagePath path: String) -> String? {
        guard let range = path.range(of: "/lib/node_modules/") else { return nil }
        let prefix = String(path[path.startIndex..<range.lowerBound])
        return prefix.isEmpty ? nil : prefix
    }

    /// `path` is what `which` found; `resolvedPath` is what it points at, which
    /// is where the truth is — the launcher is nearly always a symlink.
    static func source(
        path: String,
        resolvedPath: String?,
        provider: AgentProvider
    ) -> AgentInstallSource {
        let resolved = resolvedPath ?? path

        // Unambiguous: nothing but Homebrew writes into these.
        if resolved.contains("/Caskroom/") || resolved.contains("/Cellar/") {
            return .homebrew(formula: brewFormula(for: provider))
        }

        // Before any prefix check, and deliberately: a package installed with
        // `npm install -g` under Homebrew's Node lives at
        // `/opt/homebrew/lib/node_modules/…`. That is an npm install that
        // happens to sit inside Homebrew's tree, and `brew upgrade` cannot
        // touch it.
        if let prefix = npmPrefix(fromPackagePath: resolved) {
            return .npm(prefix: prefix)
        }

        if resolved.contains("/.volta/") || path.contains("/.volta/") {
            return .volta
        }

        // The symlink could not be followed. Fall back to recognising the
        // shape of a version manager's bin directory, where the Node root is
        // the parent of `bin`.
        if let prefix = nodeManagerPrefix(binaryPath: path) {
            return .npm(prefix: prefix)
        }

        if resolved.contains("/node_modules/") || path.contains("/node_modules/") {
            return .npm(prefix: nil)
        }

        if provider == .claude,
           resolved.contains("/.local/share/claude/") || path.contains("/.local/bin/") {
            return .nativeInstaller
        }

        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
            return .homebrew(formula: brewFormula(for: provider))
        }

        return .unknown
    }

    private static let nodeManagerMarkers = [
        "/.nvm/versions/node/",
        "/fnm/node-versions/",
        "/.asdf/installs/nodejs/",
        "/n/versions/node/",
    ]

    /// `~/.nvm/versions/node/v24.1.0/bin/gemini` → `~/.nvm/versions/node/v24.1.0`
    static func nodeManagerPrefix(binaryPath: String) -> String? {
        guard nodeManagerMarkers.contains(where: binaryPath.contains),
              binaryPath.hasSuffix("/bin/\(URL(fileURLWithPath: binaryPath).lastPathComponent)")
        else { return nil }
        return URL(fileURLWithPath: binaryPath)
            .deletingLastPathComponent()   // bin/
            .deletingLastPathComponent()   // the Node root
            .path
    }
}

/// What updating this install would actually run.
enum AgentUpdatePlan: Equatable {
    case run(String)
    /// Why not, in words a person can act on. An update button that fails
    /// silently is worse than one that explains why it is not offered.
    case cannot(String)
}

extension AgentCLIInstall {
    /// `hasNpm` decides whether a prefix really carries its own npm. pnpm and
    /// Yarn also install packages under `lib/node_modules` but keep no npm
    /// beside them, so the prefix is right and the binary is not there.
    static func updatePlan(
        provider: AgentProvider,
        source: AgentInstallSource,
        hasNpm: (String) -> Bool
    ) -> AgentUpdatePlan {
        let package = npmPackage(for: provider)
        switch source {
        case .homebrew(let formula):
            guard !formula.isEmpty else {
                return .cannot(String(localized: "Homebrew has no package for this tool."))
            }
            return .run("brew upgrade \(formula)")

        case .npm(let prefix):
            guard !package.isEmpty else {
                return .cannot(String(localized: "This tool is not published on npm."))
            }
            // That Node's own npm, so the update lands in the installation the
            // binary on PATH actually comes from.
            if let prefix, hasNpm("\(prefix)/bin/npm") {
                return .run("\"\(prefix)/bin/npm\" install -g \(package)@latest")
            }
            return .run("npm install -g \(package)@latest")

        case .volta:
            guard !package.isEmpty else {
                return .cannot(String(localized: "This tool is not published on npm."))
            }
            return .run("volta install \(package)@latest")

        case .nativeInstaller:
            return provider == .claude
                ? .run("claude update")
                : .cannot(String(localized: "This tool has no updater Uncoil knows how to run."))

        case .unknown:
            // Claude's own updater works wherever it was installed from.
            if provider == .claude { return .run("claude update") }
            // Guessing `npm install -g` here is how a second copy gets
            // installed somewhere else on PATH while the one in use stays
            // exactly as old as it was — an update that reports success and
            // changes nothing.
            return .cannot(
                String(localized: "Uncoil cannot tell how this was installed, so it will not guess at an update command.")
            )
        }
    }
}

/// What actually happened when an update ran.
enum AgentUpdateOutcome: Equatable {
    case updated(from: String?, to: String)
    /// The command succeeded and the version did not move. The case worth
    /// having: an `npm install -g` that went into a different Node exits 0 and
    /// leaves the binary on `PATH` untouched, which is exactly what "the
    /// update keeps failing" looks like from outside.
    case ranButUnchanged(version: String)
    case failed(String)

    var isFailure: Bool {
        switch self {
        case .updated: false
        case .ranButUnchanged, .failed: true
        }
    }
}

extension AgentCLIInstall {
    static func outcome(
        succeeded: Bool,
        output: String,
        before: String?,
        after: String?
    ) -> AgentUpdateOutcome {
        guard succeeded else {
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(
                message.isEmpty
                    ? String(localized: "The update command failed and said nothing.")
                    : message
            )
        }
        guard let after else {
            return .failed(String(localized: "The update ran, but the version could not be read afterwards."))
        }
        if let before, before == after {
            return .ranButUnchanged(version: after)
        }
        return .updated(from: before, to: after)
    }
}
