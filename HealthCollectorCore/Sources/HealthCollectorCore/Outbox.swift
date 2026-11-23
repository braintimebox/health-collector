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
        self.key = payload.identity.canonicalKey
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
    /// The ack could not be read. Neither success nor failure: resend later.
    case unconfirmed(error: String)
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

    public init(directory: URL) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("outbox.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            self.entries = try WireCodec.localDecoder().decode([OutboxEntry].self, from: data)
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
        let data = try WireCodec.localEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: Reading

    public var all: [OutboxEntry] { entries }

    public func entry(forKey key: String) -> OutboxEntry? {
        entries.first { $0.key == key }
    }

    public var pendingCount: Int { entries.filter { $0.state == .pending }.count }
    public var inflightCount: Int { entries.filter { $0.state == .inflight }.count }
    public var deadCount: Int { entries.filter { $0.state == .dead }.count }
    public var ackedCount: Int { entries.filter { $0.state == .acked }.count }

    public var queueDepth: Int {
        entries.filter { $0.state == .pending || $0.state == .inflight }.count
    }

    /// Age of the oldest row that still owes the server something. This is the
    /// number a status panel can trust; a cumulative "sent" counter proves
    /// nothing because it can never go down.
    public func oldestPendingAge(now: Date) -> TimeInterval? {
        let outstanding = entries
            .filter { $0.state == .pending || $0.state == .inflight }
            .map { now.timeIntervalSince($0.createdAt) }
        return outstanding.min()
    }

    public func lastAcceptedAt() -> Date? {
        entries.compactMap { $0.acceptedAt }.max()
    }

    public func lastError() -> String? {
        entries.reversed().compactMap { $0.lastError }.first
    }

    // MARK: Writing

    /// Persist before anything is sent. Returns `false` when this record is
    /// already queued: a client-side check is a latency optimisation over the
    /// server's constraint, never a replacement for it.
    @discardableResult
    public func enqueue(_ payload: OutboxPayload, now: Date) throws -> Bool {
        let key = payload.identity.canonicalKey
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
        let keys = Set(due.map { $0.key })
        for index in entries.indices where keys.contains(entries[index].key) {
            entries[index].state = .inflight
        }
        try persist()
        return due
    }

    /// Apply the server's answer to every claimed row in one write.
    public func settle(_ decisions: [String: Settlement], now: Date) throws {
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
            case let .unconfirmed(error):
                entries[index].state = .pending
                entries[index].nextAttemptAt = now
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
    public func pruneAcked() throws {
        let kept = entries.filter { $0.state != .acked }
        guard kept.count != entries.count else { return }
        entries = kept
        try persist()
    }
}
