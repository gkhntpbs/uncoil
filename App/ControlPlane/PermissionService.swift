import Foundation

/// A single directional permission record: caller (`from`) asking to act on a
/// `target` session under a named `grantKey`. Grants are directional — A→B
/// being granted never implies C→B. Persisted so decisions survive restarts.
struct PermissionRequest: Codable, Equatable, Identifiable {
    let id: String
    let grantKey: String
    let fromSessionID: String
    let targetSessionID: String?
    var status: Status
    let createdAt: Date
    var decidedAt: Date?
    /// How long the grant lasts. Optional for backward compatibility with
    /// permissions.json written before scopes existed; nil ⇒ `.persistent`.
    var scope: Scope?

    enum Status: String, Codable {
        case pending
        case granted
        case denied
        /// Nobody answered in time. Kept (rather than deleted) so the pane can
        /// say what happened instead of the request silently vanishing.
        case expired
        /// A one-time grant that has been used up.
        case consumed
    }

    enum Scope: String, Codable, CaseIterable, Identifiable {
        case once
        case persistent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .once: "Bir kez"
            case .persistent: "Kalıcı"
            }
        }
    }

    var effectiveScope: Scope { scope ?? .persistent }

    func matches(from: String, to: String?, key: String) -> Bool {
        fromSessionID == from && targetSessionID == to && grantKey == key
    }
}

/// Persists and evaluates control-plane permission requests at
/// <AppSupport>/Uncoil/permissions.json. Pending requests auto-expire after 10
/// minutes. The UI lists pending/granted entries and approves/denies/revokes
/// them; the PolicyEngine consults `isGranted` on every call (no caching).
@MainActor
final class PermissionService: ObservableObject {
    /// Default answer window for a pending request.
    static let defaultPendingTTL: TimeInterval = 10 * 60

    /// How long a request may sit unanswered before it expires. Configurable
    /// from Ayarlar → İzinler; `nil` disables expiry entirely.
    var pendingTTL: TimeInterval? = PermissionService.defaultPendingTTL

    @Published private(set) var requests: [PermissionRequest] = []

    /// Called when a fresh request is created, so the app can raise a banner.
    var onRequestCreated: ((PermissionRequest) -> Void)?

    private let fileURL: URL

    init(dataDirectory: URL) {
        fileURL = dataDirectory.appendingPathComponent("permissions.json")
        load()
    }

    // MARK: - Queries

    /// True when a GRANTED record authorizes `from` to act on `to` under `key`.
    /// Directional and exact: never widens to other callers. A one-time grant
    /// authorizes exactly this call and is marked consumed here, so the next
    /// check needs a fresh approval.
    func isGranted(from: String, to: String?, key: String) -> Bool {
        pruneExpired()
        guard let index = requests.firstIndex(where: {
            $0.status == .granted && $0.matches(from: from, to: to, key: key)
        }) else { return false }
        if requests[index].effectiveScope == .once {
            requests[index].status = .consumed
            requests[index].decidedAt = Date()
            save()
        }
        return true
    }

    /// Non-mutating: filters out expired pending records for display WITHOUT
    /// touching `@Published requests`. This is read from SwiftUI view bodies, so
    /// it must never publish changes (doing so crashes with "Publishing changes
    /// from within view updates is not allowed"). Actual pruning/persistence
    /// happens lazily on the control-plane paths (`isGranted`/`request`) and via
    /// `pruneExpiredIfNeeded()` scheduled outside any view update.
    func pending() -> [PermissionRequest] {
        guard let ttl = pendingTTL else {
            return requests.filter { $0.status == .pending }
        }
        let cutoff = Date().addingTimeInterval(-ttl)
        return requests.filter { $0.status == .pending && $0.createdAt >= cutoff }
    }

    /// Requests nobody answered in time, newest first — shown so a timeout
    /// reads as a decision rather than a disappearance.
    func expired() -> [PermissionRequest] {
        requests
            .filter { $0.status == .expired }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func granted() -> [PermissionRequest] {
        requests.filter { $0.status == .granted }
    }

    /// Prunes expired pending records off the view-update path. Safe to call
    /// from `.task`/`.onAppear`-driven async work; mutates and persists.
    func pruneExpiredIfNeeded() {
        pruneExpired()
    }

    // MARK: - Mutations

    /// Creates (or returns the existing) request for this (from, target, key).
    /// A matching granted/pending record is reused so repeated asks don't pile
    /// up; a previously denied record is reopened as pending.
    @discardableResult
    func request(grantKey: String, from: String, target: String?) -> PermissionRequest {
        pruneExpired()
        if let index = requests.firstIndex(where: {
            $0.matches(from: from, to: target, key: grantKey) && $0.status != .denied
        }) {
            return requests[index]
        }
        // Reopen a denied one in place, else append.
        if let index = requests.firstIndex(where: {
            $0.matches(from: from, to: target, key: grantKey)
        }) {
            requests[index].status = .pending
            requests[index].decidedAt = nil
            save()
            return requests[index]
        }
        let record = PermissionRequest(
            id: UUID().uuidString, grantKey: grantKey, fromSessionID: from,
            targetSessionID: target, status: .pending, createdAt: Date(), decidedAt: nil)
        requests.append(record)
        save()
        onRequestCreated?(record)
        return record
    }

    /// Approves a request. `.once` authorizes a single call; `.persistent`
    /// lasts until revoked.
    func grant(id: String, scope: PermissionRequest.Scope = .persistent) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].scope = scope
        setStatus(.granted, id: id)
    }

    func deny(id: String) { setStatus(.denied, id: id) }

    /// Proactively creates a GRANTED directional record without an agent asking
    /// first (Settings → İzinler → "İzin Ekle"). Produces the exact record shape
    /// the approve flow yields (a `.granted` PermissionRequest with `decidedAt`
    /// set), so pre-authorizing A→B is indistinguishable from approving a live
    /// request. Reuses/reopens a matching record rather than piling up.
    @discardableResult
    func addGrant(grantKey: String, from: String, target: String?) -> PermissionRequest {
        let record = request(grantKey: grantKey, from: from, target: target)
        setStatus(.granted, id: record.id)
        return requests.first { $0.id == record.id } ?? record
    }

    /// Injects a sample PENDING request so the approve/deny UI can be exercised
    /// without a live agent (dev/testing affordance). The synthetic session ids
    /// are clearly marked so the record reads as a test.
    @discardableResult
    func injectTestRequest(
        grantKey: String = "sessions.control_children",
        from: String? = nil,
        target: String? = nil
    ) -> PermissionRequest {
        let record = PermissionRequest(
            id: UUID().uuidString,
            grantKey: grantKey,
            fromSessionID: from ?? "test-\(UUID().uuidString.prefix(8))",
            targetSessionID: target ?? "test-\(UUID().uuidString.prefix(8))",
            status: .pending, createdAt: Date(), decidedAt: nil)
        requests.append(record)
        save()
        return record
    }

    /// Revokes a decision by removing the record entirely; the next attempt
    /// will require a fresh request.
    func revoke(id: String) {
        requests.removeAll { $0.id == id }
        save()
    }

    private func setStatus(_ status: PermissionRequest.Status, id: String) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].status = status
        requests[index].decidedAt = Date()
        save()
    }

    // MARK: - Expiry

    /// Marks pending requests past their TTL as expired. Granted/denied records
    /// are untouched (a persistent grant is durable until revoked).
    private func pruneExpired() {
        guard let ttl = pendingTTL else { return }
        let cutoff = Date().addingTimeInterval(-ttl)
        var changed = false
        for index in requests.indices
        where requests[index].status == .pending && requests[index].createdAt < cutoff {
            requests[index].status = .expired
            requests[index].decidedAt = Date()
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Persistence (atomic write-temp-rename)

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PermissionRequest].self, from: data) else { return }
        requests = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(requests) else { return }
        AtomicFile.write(data, to: fileURL)
    }
}
