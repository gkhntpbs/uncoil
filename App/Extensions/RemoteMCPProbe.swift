import Foundation

/// What a remote MCP server says about itself.
///
/// A remote server has no local git revision, so none of Uncoil's update
/// machinery applies to it: the version is whatever the running server reports,
/// and a repository version — even for the same project — is a different fact
/// that must not be shown in its place.
struct RemoteMCPStatus: Equatable {
    enum Reachability: Equatable {
        case reachable
        case authenticationRequired(String)
        case unreachable(String)
        /// A STDIO "remote" is a local process; its health belongs to the
        /// supervisor, not to an HTTP probe.
        case localProcess

        var label: String {
            switch self {
            case .reachable: String(localized: "Reachable")
            case .authenticationRequired: String(localized: "Authentication required")
            case .unreachable: String(localized: "Unreachable")
            case .localProcess: String(localized: "Local process")
            }
        }

        var isHealthy: Bool { self == .reachable }
    }

    var url: String
    var transport: MCPTransport
    var reachability: Reachability
    /// Version the server reported, if it reported one. Never filled in from a
    /// repository.
    var serverVersion: String?
    var serverName: String?
    var reportedCapabilities: [String] = []
    var checkedAt: Date

    /// Only the server can answer this, so an unreachable server has no version
    /// rather than a stale one.
    var versionLabel: String {
        serverVersion ?? "the server reported no version"
    }
}

/// Difference between the capabilities Uncoil recorded and what the server now
/// reports — the reason a remote server needs a diff at all: it can change under
/// you without any file changing.
struct RemoteMCPCapabilityDiff: Equatable {
    var added: [String]
    var removed: [String]
    var unchanged: [String]

    var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    var summary: String {
        if isEmpty { return String(localized: "No changes") }
        var parts: [String] = []
        if !added.isEmpty { parts.append(String(localized: "+\(added.joined(separator: ", "))")) }
        if !removed.isEmpty { parts.append(String(localized: "-\(removed.joined(separator: ", "))")) }
        return parts.joined(separator: String(localized: " · "))
    }

    static func between(known: [String], reported: [String]) -> RemoteMCPCapabilityDiff {
        let knownSet = Set(known)
        let reportedSet = Set(reported)
        return RemoteMCPCapabilityDiff(
            added: reportedSet.subtracting(knownSet).sorted(),
            removed: knownSet.subtracting(reportedSet).sorted(),
            unchanged: knownSet.intersection(reportedSet).sorted()
        )
    }
}

/// Health check for a remote MCP endpoint.
///
/// The transport call is injected so the decision logic is testable without a
/// network, and so a probe can never be made by accident from a unit test.
struct RemoteMCPProbe {
    /// What a transport hands back: HTTP status and body, or an error.
    struct Response: Equatable {
        var statusCode: Int
        var body: String
    }

    enum ProbeError: LocalizedError, Equatable {
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .transport(let message): message
            }
        }
    }

    /// Injected; the app passes a URLSession-backed implementation.
    var send: (URL) async throws -> Response

    func probe(
        url: String,
        transport: MCPTransport,
        now: Date = .now
    ) async -> RemoteMCPStatus {
        guard transport == .http else {
            return RemoteMCPStatus(
                url: url, transport: transport, reachability: .localProcess, checkedAt: now
            )
        }
        guard let endpoint = URL(string: url), endpoint.scheme?.hasPrefix("http") == true else {
            return RemoteMCPStatus(
                url: url, transport: transport,
                reachability: .unreachable("Invalid URL"), checkedAt: now
            )
        }
        do {
            return Self.evaluate(try await send(endpoint), url: url, transport: transport, now: now)
        } catch {
            return RemoteMCPStatus(
                url: url, transport: transport,
                reachability: .unreachable(error.localizedDescription), checkedAt: now
            )
        }
    }

    /// Pure: turns a response into a status.
    static func evaluate(
        _ response: Response,
        url: String,
        transport: MCPTransport,
        now: Date = .now
    ) -> RemoteMCPStatus {
        var status = RemoteMCPStatus(
            url: url, transport: transport, reachability: .unreachable("HTTP \(response.statusCode)"),
            checkedAt: now
        )
        switch response.statusCode {
        case 401, 403:
            status.reachability = .authenticationRequired(
                "The server returned \(response.statusCode); a token is required."
            )
        case 200...299:
            status.reachability = .reachable
        default:
            return status
        }

        // Fields are read where MCP puts them, and their absence is reported as
        // absence rather than filled in from somewhere else.
        guard let data = response.body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return status
        }
        let result = root["result"] as? [String: Any] ?? root
        if let info = result["serverInfo"] as? [String: Any] {
            status.serverName = info["name"] as? String
            status.serverVersion = info["version"] as? String
        }
        if let capabilities = result["capabilities"] as? [String: Any] {
            status.reportedCapabilities = capabilities.keys.sorted()
        }
        return status
    }
}
