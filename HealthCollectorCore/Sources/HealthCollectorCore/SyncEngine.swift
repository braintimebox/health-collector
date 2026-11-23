import Foundation

/// What one drain did. Counts come from applied settlements, not from "the call
/// returned", so a batch the server silently dropped reads as `unconfirmed`.
public struct SyncReport: Equatable {
    public let claimed: Int
    public let accepted: Int
    public let retried: Int
    public let deadLettered: Int
    public let unconfirmed: Int
    public let error: String?

    public static let idle = SyncReport(
        claimed: 0, accepted: 0, retried: 0, deadLettered: 0, unconfirmed: 0, error: nil
    )

    public init(
        claimed: Int,
        accepted: Int,
        retried: Int,
        deadLettered: Int,
        unconfirmed: Int,
        error: String?
    ) {
        self.claimed = claimed
        self.accepted = accepted
        self.retried = retried
        self.deadLettered = deadLettered
        self.unconfirmed = unconfirmed
        self.error = error
    }

    public var didWork: Bool { claimed > 0 }
}

/// Drains the outbox once. Deliberately synchronous and clock-injectable: every
/// failure path in here is a unit test, and none of it needs a phone.
public struct SyncEngine {
    public let userID: String
    private let store: OutboxStore
    private let transport: OutboxTransport
    private let policy: RetryPolicy
    private let batchLimit: Int

    public init(
        userID: String,
        store: OutboxStore,
        transport: OutboxTransport,
        policy: RetryPolicy = RetryPolicy(),
        batchLimit: Int = 500
    ) {
        self.userID = userID
        self.store = store
        self.transport = transport
        self.policy = policy
        self.batchLimit = batchLimit
    }

    public func drain(now: Date, jitter: Double = 0.5) throws -> SyncReport {
        let claimed = try store.claim(now: now, limit: batchLimit)
        guard !claimed.isEmpty else { return .idle }

        let batch = WireBatch(
            userID: userID,
            records: claimed.compactMap { $0.payload.record },
            deletes: claimed.compactMap { $0.payload.deletion }
        )

        do {
            let ack = try transport.send(batch)
            return try apply(ack: ack, claimed: claimed, now: now, jitter: jitter)
        } catch let failure as TransportFailure {
            return try settleFailure(failure, claimed: claimed, now: now, jitter: jitter)
        } catch {
            let wrapped = TransportFailure(
                kind: .transport,
                message: "unclassified transport error: \(error)"
            )
            return try settleFailure(wrapped, claimed: claimed, now: now, jitter: jitter)
        }
    }

    // MARK: Applying an answer

    private func apply(
        ack: ServerAck,
        claimed: [OutboxEntry],
        now: Date,
        jitter: Double
    ) throws -> SyncReport {
        let accepted = Set(ack.accepted.map { $0.lowercased() })
        let rejected = Dictionary(
            ack.rejected.map { ($0.recordID.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var decisions: [String: Settlement] = [:]
        var acceptedCount = 0
        var retriedCount = 0
        var deadCount = 0
        var unconfirmedCount = 0

        for entry in claimed {
            let recordID = entry.payload.identity.recordID.lowercased()
            if accepted.contains(recordID) || accepted.contains(entry.key) {
                decisions[entry.key] = .accepted
                acceptedCount += 1
                continue
            }
            if let rejection = rejected[recordID] {
                if rejection.permanent {
                    decisions[entry.key] = .dead(error: rejection.reason)
                    deadCount += 1
                } else {
                    let delay = policy.delay(forAttempt: entry.attempt + 1, jitter: jitter)
                    decisions[entry.key] = .retry(delay: delay, error: rejection.reason)
                    retriedCount += 1
                }
                continue
            }
            // The server named neither. That is a partial ack: keep the row and
            // resend only this one, instead of failing the whole batch.
            let delay = policy.delay(forAttempt: entry.attempt + 1, jitter: jitter)
            decisions[entry.key] = .retry(delay: delay, error: "not acknowledged by server")
            retriedCount += 1
        }

        try store.settle(decisions, now: now)
        return SyncReport(
            claimed: claimed.count,
            accepted: acceptedCount,
            retried: retriedCount,
            deadLettered: deadCount,
            unconfirmed: unconfirmedCount,
            error: nil
        )
    }

    private func settleFailure(
        _ failure: TransportFailure,
        claimed: [OutboxEntry],
        now: Date,
        jitter: Double
    ) throws -> SyncReport {
        let classification = policy.classification(for: failure)
        var decisions: [String: Settlement] = [:]

        for entry in claimed {
            switch classification {
            case .unconfirmed:
                decisions[entry.key] = .unconfirmed(error: failure.message)
            case .retryable:
                let backoff = policy.delay(forAttempt: entry.attempt + 1, jitter: jitter)
                // A server that says "come back in 60 s" knows more than our
                // schedule does; honour it, but never retry sooner than backoff.
                let delay = max(failure.retryAfter ?? 0, backoff)
                decisions[entry.key] = .retry(delay: delay, error: failure.message)
            case .permanent:
                decisions[entry.key] = .dead(error: failure.message)
            }
        }

        try store.settle(decisions, now: now)

        switch classification {
        case .unconfirmed:
            return SyncReport(claimed: claimed.count, accepted: 0, retried: 0, deadLettered: 0, unconfirmed: claimed.count, error: failure.message)
        case .retryable:
            return SyncReport(claimed: claimed.count, accepted: 0, retried: claimed.count, deadLettered: 0, unconfirmed: 0, error: failure.message)
        case .permanent:
            return SyncReport(claimed: claimed.count, accepted: 0, retried: 0, deadLettered: claimed.count, unconfirmed: 0, error: failure.message)
        }
    }
}
