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
    private let spool: BatchSpool?

    public init(
        userID: String,
        store: OutboxStore,
        transport: OutboxTransport,
        policy: RetryPolicy = RetryPolicy(),
        batchLimit: Int = 500,
        spool: BatchSpool? = nil
    ) {
        self.userID = userID
        self.store = store
        self.transport = transport
        self.policy = policy
        self.batchLimit = batchLimit
        self.spool = spool
    }

    public func drain(now: Date, jitter: Double = 0.5) throws -> SyncReport {
        let claimed = try store.claim(now: now, limit: batchLimit)
        guard !claimed.isEmpty else { return .idle }

        let batch = WireBatch(
            userID: userID,
            records: claimed.compactMap { $0.payload.record },
            deletes: claimed.compactMap { $0.payload.deletion }
        )

        // A local defect (a record built for another user) is caught before a byte
        // leaves the phone: the server would answer 401 for the whole batch, and that
        // reads as a credential problem.
        try MeasurementClient.validate(batch)

        do {
            // A file-backed transport uploads from disk, so the batch is written
            // first and the file is removed once the answer is applied: an upload
            // that outlives the process must still have something to read.
            if let spool, let fileTransport = transport as? FileBackedTransport {
                let url = try spool.write(batch)
                defer { spool.remove(url) }
                let ack = try fileTransport.send(fileAt: url, userID: userID)
                return try apply(ack: ack, claimed: claimed, now: now, jitter: jitter)
            }
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

    /// Persist the next batch as a file without sending it, for the caller to hand
    /// to `uploadTask(with:fromFile:)`.
    ///
    /// Rows are claimed (inflight) here, so a process that dies between spooling
    /// and starting the upload returns them to pending on the next launch instead
    /// of stranding them.
    public func spoolNextBatch(now: Date) throws -> URL? {
        guard let spool, transport is FileBackedTransport else { return nil }
        let claimed = try store.claim(now: now, limit: batchLimit)
        guard !claimed.isEmpty else { return nil }
        let batch = WireBatch(
            userID: userID,
            records: claimed.compactMap { $0.payload.record },
            deletes: claimed.compactMap { $0.payload.deletion }
        )
        try MeasurementClient.validate(batch)
        return try spool.write(batch)
    }

    // MARK: Applying an answer

    /// Apply an answer that arrived after the fact — the background upload
    /// finished while the app was suspended, and the session delegate handed over
    /// the response. The batch is read back from the spool file it was uploaded
    /// from, so the rows are settled by what was actually sent, not by a copy in
    /// memory that a relaunch would have lost.
    public func settleSpooled(
        fileAt url: URL,
        ack: ServerAck,
        now: Date,
        jitter: Double = 0.5
    ) throws -> SyncReport {
        guard let spool else { return .idle }
        let batch = try spool.read(at: url)
        var ids = Set(batch.records.map { $0.identity.recordID.lowercased() })
        ids.formUnion(batch.deletes.map { $0.identity.recordID.lowercased() })
        let claimed = store.all.filter {
            $0.state == .inflight && ids.contains($0.payload.identity.recordID.lowercased())
        }
        defer { spool.remove(url) }
        guard !claimed.isEmpty else {
            return SyncReport(claimed: 0, accepted: 0, retried: 0, deadLettered: 0, unconfirmed: 0, error: nil)
        }
        return try apply(ack: ack, claimed: claimed, now: now, jitter: jitter)
    }

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
        let unconfirmedCount = 0
        for entry in claimed {
            let recordID = entry.payload.identity.recordID.lowercased()
            if accepted.contains(recordID)
                || accepted.contains(entry.key)
                || accepted.contains(entry.payload.identity.canonicalKey) {
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
