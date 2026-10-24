import Foundation

/// One concrete host found in an SSH config, and where.
struct SSHConfigEntry: Equatable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    /// The file and 1-based line of the first `Host` line naming this alias.
    var sourcePath: String
    var line: Int

    var asHost: SSHHost {
        SSHHost(alias: alias, hostName: hostName, user: user, port: port,
                identityFile: identityFile, origin: .system)
    }
}

/// Reads the concrete host aliases out of `~/.ssh/config`.
///
/// Deliberately not an SSH config evaluator. It answers "which names can
/// `ssh <name>` be given", which is all Uncoil needs to offer: `Host` lines are
/// split into their patterns, the ones with `*`, `?` or `!` are skipped as
/// patterns rather than hosts, `Match` blocks are skipped whole, and `Include`
/// is followed the way OpenSSH follows it — relative to `~/.ssh`, with globs.
/// For a host's real resolved settings `ssh -G` is the authority; the fields
/// here are the first value written for the alias, which is what OpenSSH would
/// use when nothing more general came first.
struct SSHConfigParser {
    /// `~/.ssh`. Relative includes resolve against it.
    var sshDirectory: URL
    /// Files never read — Uncoil's own config, so its hosts are not found
    /// again as if the user had written them.
    var excludedPaths: Set<String> = []

    static let maximumIncludeDepth = 16

    func parse(configURL: URL? = nil) -> [SSHConfigEntry] {
        var state = State()
        let root = configURL ?? sshDirectory.appendingPathComponent("config")
        read(root, depth: 0, state: &state)
        return state.order.compactMap { state.entries[$0] }
    }

    /// Parses config text directly; `Include` still resolves against disk.
    func parse(text: String, sourcePath: String = "config") -> [SSHConfigEntry] {
        var state = State()
        read(text: text, path: sourcePath, depth: 0, state: &state)
        return state.order.compactMap { state.entries[$0] }
    }

    // MARK: - Reading

    private struct State {
        var entries: [String: SSHConfigEntry] = [:]
        var order: [String] = []
        var visited: Set<String> = []
    }

    private func read(_ url: URL, depth: Int, state: inout State) {
        let path = url.standardizedFileURL.path
        guard depth <= Self.maximumIncludeDepth,
              !excludedPaths.contains(path),
              !state.visited.contains(path),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        state.visited.insert(path)
        read(text: text, path: path, depth: depth, state: &state)
    }

    private func read(text: String, path: String, depth: Int, state: inout State) {
        // The aliases the current block applies to; nil inside a `Match` block
        // or before the first `Host`, where options belong to no single host.
        var current: [String]? = nil
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            guard let (keyword, arguments) = Self.split(rawLine) else { continue }
            switch keyword {
            case "host":
                let concrete = arguments.filter(Self.isConcrete)
                current = concrete
                for alias in concrete where state.entries[alias] == nil {
                    state.entries[alias] = SSHConfigEntry(alias: alias, sourcePath: path, line: index + 1)
                    state.order.append(alias)
                }
            case "match":
                current = nil
            case "include":
                for argument in arguments {
                    for url in resolveInclude(argument) {
                        read(url, depth: depth + 1, state: &state)
                    }
                }
            default:
                guard let aliases = current, let value = arguments.first else { continue }
                for alias in aliases {
                    guard var entry = state.entries[alias] else { continue }
                    // First value wins, as it does for OpenSSH.
                    switch keyword {
                    case "hostname": entry.hostName = entry.hostName ?? value
                    case "user": entry.user = entry.user ?? value
                    case "port": entry.port = entry.port ?? Int(value)
                    case "identityfile": entry.identityFile = entry.identityFile ?? value
                    default: break
                    }
                    state.entries[alias] = entry
                }
            }
        }
    }

    /// The files one `Include` argument names, sorted the way `glob(3)` does.
    func resolveInclude(_ argument: String) -> [URL] {
        var pattern = argument
        if pattern.hasPrefix("~/") {
            pattern = sshDirectory.deletingLastPathComponent()
                .appendingPathComponent(String(pattern.dropFirst(2))).path
        } else if !pattern.hasPrefix("/") {
            pattern = sshDirectory.appendingPathComponent(pattern).path
        }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    // MARK: - Lexing

    /// `Keyword value…` or `Keyword=value…`, lowercased keyword; nil for blank
    /// lines and comments.
    static func split(_ line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var tokens = tokenize(trimmed)
        guard !tokens.isEmpty else { return nil }
        var keyword = tokens.removeFirst()
        if let equals = keyword.firstIndex(of: "=") {
            let rest = String(keyword[keyword.index(after: equals)...])
            keyword = String(keyword[..<equals])
            if !rest.isEmpty { tokens.insert(rest, at: 0) }
        } else if tokens.first == "=" {
            tokens.removeFirst()
        } else if let first = tokens.first, first.hasPrefix("=") {
            tokens[0] = String(first.dropFirst())
        }
        return (keyword.lowercased(), tokens.filter { !$0.isEmpty })
    }

    /// Whitespace-separated words, with double quotes grouping. A `#` that
    /// starts a word ends the line, as OpenSSH treats it.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                hasToken = true
            } else if !quoted, character == " " || character == "\t" {
                if hasToken { tokens.append(current) }
                current = ""
                hasToken = false
            } else if !quoted, character == "#", !hasToken {
                break
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    /// A pattern names many hosts; only a plain name is one `ssh` can be given.
    static func isConcrete(_ pattern: String) -> Bool {
        !pattern.contains(where: { "*?!".contains($0) })
    }
}
