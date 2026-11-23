import Foundation
import HealthCollectorCore

/// A directory keyed to the test that owns it, deleted on deinit.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hcc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func child(_ name: String) throws -> URL {
        let child = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return child
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func makeRecord(
    _ index: Int,
    user: String = "user-1",
    type: String = "heart_rate_variability",
    unit: String = "ms",
    value: Double = 65.4
) -> HealthRecord {
    HealthRecord(
        identity: RecordIdentity(
            userID: user,
            recordID: String(format: "8F14E45F-CEED-4C45-9D1A-%012d", index)
        ),
        type: type,
        value: value,
        unit: unit,
        // The spec fixes the wire timestamps as ISO 8601 UTC; the local zone
        // travels in `time_zone` and is never folded into the instant.
        startDate: "2026-11-23T06:30:00.000Z",
        endDate: "2026-11-23T06:30:00.000Z",
        timeZone: "Europe/Warsaw",
        sourceName: "Apple Watch",
        sourceID: "com.apple.health.watch"
    )
}

func makeDeletion(of record: HealthRecord, at instant: String = "2026-11-23T07:00:00.000Z") -> DeletedRecord {
    DeletedRecord(identity: record.identity, deletedAt: instant, sourceName: record.sourceName)
}

/// In-memory stand-in for the server: a unique constraint on
/// `(user, record uuid)`, soft deletes as tombstones, and switches for every
/// failure shape the client has to survive.
final class FakeServer: OutboxTransport {
    enum AckMode {
        /// Everything in the batch is named as stored.
        case all
        /// Only the first id is named — the partial-ack case.
        case firstOnly
        /// Names nothing, but stores everything.
        case none
        /// Stores everything, then answers with something that is not an ack.
        case unparseable
    }

    private(set) var rows: [String: Double] = [:]
    private(set) var tombstones: Set<String> = []
    private(set) var batches: [WireBatch] = []
    /// How many times a client tried to insert a record the user had deleted.
    private(set) var resurrectionAttempts = 0

    var failure: TransportFailure?
    var ackMode: AckMode = .all

    var rowCount: Int { rows.count }

    func send(_ batch: WireBatch) throws -> ServerAck {
        batches.append(batch)
        if let failure {
            throw failure
        }

        var accepted: [String] = []

        for record in batch.records {
            let key = record.identity.canonicalKey
            if tombstones.contains(key) {
                // Idempotent and non-resurrecting: the insert is acknowledged (so
                // the client stops retrying) but never stored.
                resurrectionAttempts += 1
                accepted.append(record.identity.recordID)
                continue
            }
            rows[key] = record.value
            accepted.append(record.identity.recordID)
        }

        for deletion in batch.deletes {
            let key = deletion.identity.canonicalKey
            // A delete for an id never seen is still recorded — otherwise a later
            // backfill resurrects it.
            tombstones.insert(key)
            rows.removeValue(forKey: key)
            accepted.append(deletion.identity.recordID)
        }

        switch ackMode {
        case .all:
            return ServerAck(accepted: accepted)
        case .firstOnly:
            return ServerAck(accepted: Array(accepted.prefix(1)))
        case .none:
            return ServerAck(accepted: [])
        case .unparseable:
            throw TransportFailure(kind: .malformedAck, message: "response body is not an ack object")
        }
    }
}

/// Scripted source: one queued answer per call, or one failure for all calls.
final class ScriptedSource: HealthSource {
    private var answers: [String: [FetchResult]] = [:]
    var failure: HealthSourceFailure?
    private(set) var fetchedTypes: [String] = []

    func queue(_ result: FetchResult, for type: String) {
        answers[type, default: []].append(result)
    }

    func fetch(for type: String, since cursor: String?) throws -> FetchResult {
        fetchedTypes.append(type)
        if let failure {
            throw failure
        }
        var queue = answers[type] ?? []
        guard !queue.isEmpty else {
            return FetchResult(cursor: cursor ?? "empty", inserted: [], deleted: [])
        }
        let next = queue.removeFirst()
        answers[type] = queue
        return next
    }
}

let t0 = Date(timeIntervalSince1970: 1_763_000_000)
