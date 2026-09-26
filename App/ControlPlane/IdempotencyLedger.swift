import Foundation

/// Remembers what an effect returned, so a retry cannot do it twice.
///
/// An MCP client that times out does not know whether its call ran. If it
/// sends the same call again with the same `idempotency_key`, the ledger
/// returns the first answer instead of submitting the prompt — or answering
/// the approval — a second time. A retry that arrives while the first call is
/// still running waits for it rather than racing it.
///
/// Held in memory: it covers a client retrying, which happens in seconds, not
/// an app restart, after which there is nothing in flight to repeat.
@MainActor
final class IdempotencyLedger {
    static let lifetime: TimeInterval = 15 * 60
    static let capacity = 512

    private enum State {
        case running(Task<ControlEnvelope, Never>)
        case finished(ControlEnvelope)
    }

    private struct Entry {
        let fingerprint: String
        let date: Date
        var state: State
    }

    private var entries: [String: Entry] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Runs `body` once per key. A key reused with different arguments is a
    /// client bug, and says so rather than returning an answer to a question
    /// that was not asked.
    func run(
        key: String,
        request: ControlRequest,
        body: @escaping @MainActor () async -> ControlEnvelope
    ) async -> ControlEnvelope {
        prune()
        let fingerprint = Self.fingerprint(request)
        if let entry = entries[key] {
            guard entry.fingerprint == fingerprint else {
                return .failure(
                    request, code: .idempotencyConflict,
                    message: "idempotency_key was already used with different arguments")
            }
            let original: ControlEnvelope
            switch entry.state {
            case .finished(let envelope): original = envelope
            case .running(let task): original = await task.value
            }
            return Self.replay(original, for: request)
        }
        let task = Task { @MainActor in await body() }
        entries[key] = Entry(fingerprint: fingerprint, date: now(), state: .running(task))
        let envelope = await task.value
        // A failure worth retrying must stay retryable: remembering it would
        // turn "not ready yet" into a permanent answer.
        if !envelope.ok, envelope.error?.retryable == true || envelope.error?.code == ControlErrorCode.cancelled.rawValue {
            entries[key] = nil
        } else {
            entries[key]?.state = .finished(envelope)
        }
        return envelope
    }

    static func key(for request: ControlRequest, idempotencyKey: String) -> String {
        [request.caller_session_id ?? "", request.capability, request.action, idempotencyKey]
            .joined(separator: "\u{1F}")
    }

    /// The arguments as sorted JSON, so key order does not change the answer.
    static func fingerprint(_ request: ControlRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(request.args)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func replay(_ original: ControlEnvelope, for request: ControlRequest) -> ControlEnvelope {
        var envelope = original
        envelope.request_id = request.request_id
        envelope.warnings.append("idempotent_replay: returned the result of the first call with this idempotency_key")
        return envelope
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.lifetime)
        entries = entries.filter { _, entry in
            if case .running = entry.state { return true }
            return entry.date >= cutoff
        }
        if entries.count > Self.capacity {
            let oldest = entries.sorted { $0.value.date < $1.value.date }
                .prefix(entries.count - Self.capacity).map(\.key)
            for key in oldest { entries[key] = nil }
        }
    }
}
