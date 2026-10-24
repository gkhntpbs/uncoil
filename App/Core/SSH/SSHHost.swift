import Foundation

/// A machine an agent can reach with plain `ssh <alias>`.
///
/// The alias is the identity, because it is the only thing the agent ever
/// types: two entries with the same alias would be one host to OpenSSH, and a
/// project association that pointed at anything else would survive a host
/// being redefined under the same name without anyone noticing.
///
/// Where it came from decides who may change it. A `.system` host lives in the
/// user's own SSH config and Uncoil only remembers it — its connection fields
/// are a snapshot refreshed on every scan, and only the note is Uncoil's. An
/// `.uncoil` host is Uncoil's to write, into `~/.ssh/uncoil_config`.
struct SSHHost: Codable, Equatable, Hashable, Identifiable {
    enum Origin: String, Codable {
        /// Found in the user's SSH config; read-only here.
        case system
        /// Written by Uncoil to `~/.ssh/uncoil_config`.
        case uncoil
    }

    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    /// What the machine is for, in the user's words. Shown to agents.
    var note: String?
    var origin: Origin

    var id: String { alias }

    init(
        alias: String,
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        note: String? = nil,
        origin: Origin
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.note = note
        self.origin = origin
    }

    /// `user@host:port`, with whatever parts are known; nil when none are.
    var destinationSummary: String? {
        guard hostName != nil || user != nil || port != nil else { return nil }
        var text = hostName ?? alias
        if let user { text = "\(user)@\(text)" }
        if let port { text += ":\(port)" }
        return text
    }

    /// Whether `alias` is something `ssh <alias>` can name on its own.
    ///
    /// Patterns are refused because a `Host` line with `*`, `?` or `!` matches
    /// many machines and is no single host an agent could be pointed at.
    static func isValidAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 128 else { return false }
        let refused = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "*?!,\"'#="))
        return alias.unicodeScalars.allSatisfy { !refused.contains($0) }
            && !alias.hasPrefix("-")
    }

    /// The note with its whitespace trimmed; nil when there is nothing in it.
    var trimmedNote: String? {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
