import Foundation

// MARK: - Source seam

/// The vendor API, behind the last seam. Everything on this side of the protocol
/// is testable; everything behind it needs a device, so it stays thin and
/// obviously correct.
public protocol HealthSource {
    func fetch(for type: String, since cursor: String?) throws -> FetchResult
}

public struct FetchResult: Equatable {
    /// The opaque cursor to store for the next call. `nil` cursor in means "the
    /// whole history", which is also the recovery path after any suspicion of
    /// loss.
    public let cursor: String
    public let inserted: [HealthRecord]
    public let deleted: [DeletedRecord]

    public init(cursor: String, inserted: [HealthRecord], deleted: [DeletedRecord]) {
        self.cursor = cursor
        self.inserted = inserted
        self.deleted = deleted
    }
}

public enum HealthSourceFailure: Error, Equatable {
    /// The store was not readable — a locked device is the usual reason.
    /// **Not** the same as "no new data": collapsing the two turns a locked
    /// screen into a lost window.
    case storeUnreadable
    case authorizationDenied
    case queryFailed(String)
}

// MARK: - Cursors

/// One cursor per data type, on disk. `nil` means "everything from the
/// beginning" and is a legitimate stored state, not a missing value.
public final class AnchorStore {
    public let directory: URL
    private let fileURL: URL
    private var cursors: [String: String]
    /// Same model as `OutboxStore`: single owner, lock for cross-queue reads.
    private let lock = NSLock()

    public init(directory: URL) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("anchors.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            self.cursors = try WireCodec.decoder().decode([String: String].self, from: data)
        } else {
            self.cursors = [:]
        }
    }

    private func persist() throws {
        let data = try WireCodec.encoder().encode(cursors)
        try data.write(to: fileURL, options: .atomic)
    }

    public func cursor(for type: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cursors[type]
    }

    /// Passing `nil` drops the cursor back to full history. The caller is
    /// responsible for having decided that a full re-import is safe — with
    /// `(user, uuid)` identity and server-side tombstones, it is.
    public func save(_ cursor: String?, for type: String) throws {
        lock.lock()
        defer { lock.unlock() }
        cursors[type] = cursor
        try persist()
    }

    public func isFullHistory(for type: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cursors[type] == nil
    }

    public func resetAll() throws {
        lock.lock()
        defer { lock.unlock() }
        cursors = [:]
        try persist()
    }

    public var types: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cursors.keys.sorted()
    }
}

// MARK: - Collect

public struct CollectReport: Equatable {
    public let inserted: Int
    public let duplicatesSkipped: Int
    public let deleted: Int
    public let typesTouched: [String]

    public static let empty = CollectReport(inserted: 0, duplicatesSkipped: 0, deleted: 0, typesTouched: [])
}

/// Reads the source, writes the outbox, then moves the cursor.
///
/// The order is the whole contract: rows are on disk before the cursor advances,
/// so a crash replays a window instead of skipping one. The flush to the server
/// is a separate step — nothing here waits for the network.
public struct Collector {
    private let source: HealthSource
    private let outbox: OutboxStore
    private let anchors: AnchorStore
    private let types: [String]
    private let clock: () -> Date

    public init(
        source: HealthSource,
        outbox: OutboxStore,
        anchors: AnchorStore,
        types: [String],
        clock: @escaping () -> Date
    ) {
        self.source = source
        self.outbox = outbox
        self.anchors = anchors
        self.types = types
        self.clock = clock
    }

    public func collectOnce() throws -> CollectReport {
        var inserted = 0
        var skipped = 0
        var deleted = 0
        var touched: [String] = []

        for type in types {
            let cursor = anchors.cursor(for: type)
            // A read failure propagates untouched: the cursor stays where it was
            // and the next wake-up asks for the same window again.
            let result = try source.fetch(for: type, since: cursor)

            for record in result.inserted {
                if try outbox.enqueue(.insert(record), now: clock()) {
                    inserted += 1
                } else {
                    skipped += 1
                }
            }

            // Deletes are queued as their own records, behind nothing: a delete
            // that waits for its insert to be acked is dropped when the insert
            // is retried out of order.
            for deletion in result.deleted {
                if try outbox.enqueue(.delete(deletion), now: clock()) {
                    deleted += 1
                } else {
                    skipped += 1
                }
            }

            try anchors.save(result.cursor, for: type)
            touched.append(type)
        }

        return CollectReport(
            inserted: inserted,
            duplicatesSkipped: skipped,
            deleted: deleted,
            typesTouched: touched
        )
    }

    /// Recovery path: forget every cursor and re-read the whole history. Safe
    /// because identity is the vendor UUID and the server keeps tombstones.
    public func scheduleFullReimport() throws {
        try anchors.resetAll()
    }
}
