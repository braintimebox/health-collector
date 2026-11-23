import Foundation

// MARK: - Entry

/// One durable row of the outbox. Everything needed to resend it after a crash
/// is here: payload, attempt count, when it may be tried again, and why it last
/// failed. `inflight` exists only to make a process death visible, and is reset
/// to `pending` on the next launch.
public struct OutboxEntry: Codable, Equatable {
    public enum State: String, Codable {
        case pending
        case inflight
        case acked
        case dead
    }

    public let key: String
    public let payload: OutboxPayload
    public let createdAt: Date
    public var state: State
    public var attempt: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    public var acceptedAt: Date?

    public init(
        payload: OutboxPayload,
        createdAt: Date,
        state: State = .pending,
        attempt: Int = 0,
        nextAttemptAt: Date,
        lastError: String? = nil,
        acceptedAt: Date? = nil
    ) {
        self.key = payload.outboxKey
        self.payload = payload
        self.createdAt = createdAt
        self.state = state
        self.attempt = attempt
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.acceptedAt = acceptedAt
    }
}

/// How one claimed row came back from the server.
public enum Settlement: Equatable {
    case accepted
    case retry(delay: TimeInterval, error: String)
    case dead(error: String)
    /// The ack could not be read. Neither success nor failure: resend later,
    /// but never in a tight loop — an unreadable answer repeated every drain is
    /// exactly how a client hammers a server that is already struggling.
    case unconfirmed(delay: TimeInterval, error: String)
}

// MARK: - Store

/// A durable outbox on disk. The whole queue is rewritten atomically on every
/// mutation: `Data.write(options: .atomic)` writes a sibling file and renames it,
/// so a crash leaves either the old queue or the new one, never half of one.
///
/// Volume assumption: this holds unsent rows, not history. Thousands are fine,
/// millions are not — the history lives on the server, which is the point.
public final class OutboxStore {
    public let directory: URL
    private let fileURL: URL
    private var entries: [OutboxEntry]
    /// Concurrency model: one writer (the sync engine on the app's serial
    /// queue). The lock is defence in depth for diagnostics read from another
    /// queue, not a licence to mutate from several threads.
    private let lock = NSLock()

    public init(directory: URL) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("outbox.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            self.entries = try WireCodec.decoder().decode([OutboxEntry].self, from: data)
        } else {
            self.entries = []
        }
        // A row that was in flight when the process died is not lost — it is
        // unconfirmed, and must be resent. Leaving it `inflight` would strand it
        // forever, because nothing claims an inflight row.
        var recovered = false
        for index in entries.indices where entries[index].state == .inflight {
            entries[index].state = .pending
            recovered = true
        }
        if recovered {
            try persist()
        }
    }

    private func persist() throws {
        let data = try WireCodec.encoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: Reading

    public var all: [OutboxEntry] { entries }

    public func entry(forKey key: String) -> OutboxEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.key == key }
    }

    public var pendingCount: Int { entries.filter { $0.state == .pending }.count }
    public var inflightCount: Int { entries.filter { $0.state == .inflight }.count }
    public var deadCount: Int { entries.filter { $0.state == .dead }.count }
    public var ackedCount: Int { entries.filter { $0.state == .acked }.count }

    public var queueDepth: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.state == .pending || $0.state == .inflight }.count
    }

    /// Age of the oldest row that still owes the server something. This is the
    /// number a status panel can trust; a cumulative "sent" counter proves
    /// nothing because it can never go down.
    public func oldestPendingAge(now: Date) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        let outstanding = entries
            .filter { $0.state == .pending || $0.state == .inflight }
            .map { now.timeIntervalSince($0.createdAt) }
        // BUG-01: this is the age of the OLDEST outstanding row, so the largest
        // interval. `min()` reported the freshest row and made a queue that had
        // been stuck for a day look seconds old.
        return outstanding.max()
    }

    public func lastAcceptedAt() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return entries.compactMap { $0.acceptedAt }.max()
    }

    /// When the collector last put something in the queue, whatever happened to
    /// it afterwards. This is the anchor for "is this silence or is it empty":
    /// a green panel needs a recent row, not a recent run.
    public func latestRowAt() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { $0.createdAt }.max()
    }

    public func lastError() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries.reversed().compactMap { $0.lastError }.first
    }

    // MARK: Writing

    /// Persist before anything is sent. Returns `false` when this record is
    /// already queued: a client-side check is a latency optimisation over the
    /// server's constraint, never a replacement for it.
    @discardableResult
    public func enqueue(_ payload: OutboxPayload, now: Date) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = payload.outboxKey
        if entries.contains(where: { $0.key == key }) {
            return false
        }
        entries.append(OutboxEntry(payload: payload, createdAt: now, nextAttemptAt: now))
        try persist()
        return true
    }

    /// Take up to `limit` rows that are due, marking them inflight in the same
    /// write. Oldest first, so a long outage drains in the order it accumulated.
    public func claim(now: Date, limit: Int) throws -> [OutboxEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0 else { return [] }
        let due = entries
            .filter { $0.state == .pending && $0.nextAttemptAt <= now }
            // Ties broken by key: `sorted` is not a stable sort, and a
            // non-deterministic drain order makes a partial-ack test flaky.
            .sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.key < rhs.key : lhs.createdAt < rhs.createdAt
            }
            .prefix(limit)
        guard !due.isEmpty else { return [] }
        // BUG-03: the server's ack names a record_id, not an operation. An insert
        // and a delete for the same identity in one batch would make that answer
        // ambiguous — both rows would be settled by a single id. Keep each batch
        // to one operation per identity; the other row waits for the next drain.
        var seenIdentities = Set<String>()
        var claimed: [OutboxEntry] = []
        for entry in due {
            let identity = entry.payload.identity.canonicalKey
            guard !seenIdentities.contains(identity) else { continue }
            seenIdentities.insert(identity)
            claimed.append(entry)
        }
        guard !claimed.isEmpty else { return [] }
        let keys = Set(claimed.map { $0.key })
        for index in entries.indices where keys.contains(entries[index].key) {
            entries[index].state = .inflight
        }
        try persist()
        return claimed
    }

    /// Apply the server's answer to every claimed row in one write.
    public func settle(_ decisions: [String: Settlement], now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for index in entries.indices {
            guard let decision = decisions[entries[index].key] else { continue }
            changed = true
            switch decision {
            case .accepted:
                entries[index].state = .acked
                entries[index].acceptedAt = now
            case let .retry(delay, error):
                entries[index].state = .pending
                entries[index].attempt += 1
                entries[index].nextAttemptAt = now.addingTimeInterval(delay)
                entries[index].lastError = error
            case let .dead(error):
                entries[index].state = .dead
                entries[index].attempt += 1
                entries[index].lastError = error
            case let .unconfirmed(delay, error):
                entries[index].state = .pending
                entries[index].attempt += 1
                entries[index].nextAttemptAt = now.addingTimeInterval(delay)
                entries[index].lastError = error
            }
        }
        if changed {
            try persist()
        }
    }

    /// Put every inflight row back without changing its attempt count. Used when
    /// the process is about to be suspended mid-batch.
    public func requeueInflight() throws {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for index in entries.indices where entries[index].state == .inflight {
            entries[index].state = .pending
            changed = true
        }
        if changed {
            try persist()
        }
    }

    /// Drop rows the server has confirmed. Never touches pending or dead rows.
    ///
    /// `keeping` keeps the newest acked rows so the diagnostics panel can still
    /// answer "when did the last successful send happen". Without a call to this
    /// the queue grows forever: acked rows were never pruned at all.
    public func pruneAcked(keeping: Int = 200) throws {
        lock.lock()
        defer { lock.unlock() }
        let acked = entries.filter { $0.state == .acked }
        guard acked.count > keeping else { return }
        let survivors = Set(
            acked.sorted { $0.createdAt > $1.createdAt }.prefix(keeping).map { $0.key }
        )
        let kept = entries.filter { $0.state != .acked || survivors.contains($0.key) }
        guard kept.count != entries.count else { return }
        entries = kept
        try persist()
    }
}
