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

    enum Status: String, Codable {
        case pending
        case granted
        case denied
    }

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
    /// Pending requests older than this are dropped when the list is read.
    static let pendingTTL: TimeInterval = 10 * 60

    @Published private(set) var requests: [PermissionRequest] = []

    private let fileURL: URL

    init(dataDirectory: URL) {
        fileURL = dataDirectory.appendingPathComponent("permissions.json")
        load()
    }

    // MARK: - Queries

    /// True when a non-expired GRANTED record authorizes `from` to act on `to`
    /// under `key`. Directional and exact: never widens to other callers.
    func isGranted(from: String, to: String?, key: String) -> Bool {
        pruneExpired()
        return requests.contains {
            $0.status == .granted && $0.matches(from: from, to: to, key: key)
        }
    }

    /// Non-mutating: filters out expired pending records for display WITHOUT
    /// touching `@Published requests`. This is read from SwiftUI view bodies, so
    /// it must never publish changes (doing so crashes with "Publishing changes
    /// from within view updates is not allowed"). Actual pruning/persistence
    /// happens lazily on the control-plane paths (`isGranted`/`request`) and via
    /// `pruneExpiredIfNeeded()` scheduled outside any view update.
    func pending() -> [PermissionRequest] {
        let cutoff = Date().addingTimeInterval(-Self.pendingTTL)
        return requests.filter { $0.status == .pending && $0.createdAt >= cutoff }
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
        return record
    }

    func grant(id: String) { setStatus(.granted, id: id) }
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

    /// Drops pending requests past their TTL. Granted/denied records are kept
    /// (a grant is durable until revoked).
    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-Self.pendingTTL)
        let before = requests.count
        requests.removeAll { $0.status == .pending && $0.createdAt < cutoff }
        if requests.count != before { save() }
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
