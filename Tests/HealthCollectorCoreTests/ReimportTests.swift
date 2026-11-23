import XCTest
import HealthCollectorCore

/// A7 and row 8: a full re-import (fresh install, wiped container, manual
/// recovery) must neither duplicate a record nor resurrect a deleted one — and a
/// cursor may never move past a row that was not written to disk.
final class ReimportTests: XCTestCase {
    private let hrv = "heart_rate_variability"

    func testFullReimportAfterCleanInstallDoesNotResurrectDeletedRecords() throws {
        let dir = try TempDirectory()
        let server = FakeServer()
        let a = makeRecord(1, value: 61.5)
        let b = makeRecord(2, value: 70.0)

        // Session 1: both measurements collected and delivered.
        let outbox1 = try OutboxStore(directory: try dir.child("outbox-1"))
        let anchors1 = try AnchorStore(directory: try dir.child("anchors-1"))
        let source1 = ScriptedSource()
        source1.queue(FetchResult(cursor: "c1", inserted: [a, b], deleted: []), for: hrv)
        let collector1 = Collector(source: source1, outbox: outbox1, anchors: anchors1, types: [hrv], clock: { t0 })
        XCTAssertEqual(try collector1.collectOnce().inserted, 2)

        let engine1 = SyncEngine(userID: "user-1", store: outbox1, transport: server)
        XCTAssertEqual(try engine1.drain(now: t0).accepted, 2)
        XCTAssertEqual(server.rowCount, 2)
        XCTAssertEqual(anchors1.cursor(for: hrv), "c1")

        // Session 2: the user deletes B in Health.
        source1.queue(FetchResult(cursor: "c2", inserted: [], deleted: [makeDeletion(of: b)]), for: hrv)
        XCTAssertEqual(try collector1.collectOnce().deleted, 1)
        _ = try engine1.drain(now: t0.addingTimeInterval(60))
        XCTAssertEqual(server.rowCount, 1, "the delete is durable, not a local-only view")

        // Session 3: clean reinstall — new outbox, new cursor, server untouched.
        // Health still contains both measurements, so the backfill returns both.
        let outbox2 = try OutboxStore(directory: try dir.child("outbox-2"))
        let anchors2 = try AnchorStore(directory: try dir.child("anchors-2"))
        XCTAssertTrue(anchors2.isFullHistory(for: hrv), "a fresh cursor means the whole history")

        let source2 = ScriptedSource()
        source2.queue(FetchResult(cursor: "c1", inserted: [a, b], deleted: []), for: hrv)
        let collector2 = Collector(source: source2, outbox: outbox2, anchors: anchors2, types: [hrv], clock: { t0.addingTimeInterval(120) })
        XCTAssertEqual(try collector2.collectOnce().inserted, 2)

        let engine2 = SyncEngine(userID: "user-1", store: outbox2, transport: server)
        let report = try engine2.drain(now: t0.addingTimeInterval(120))

        XCTAssertEqual(report.accepted, 2, "the tombstoned record is acknowledged, so it is not retried forever")
        XCTAssertEqual(server.rowCount, 1, "a backfill must not resurrect a deleted measurement")
        XCTAssertEqual(server.resurrectionAttempts, 1)
        XCTAssertEqual(outbox2.queueDepth, 0, "a permanent tombstone must not loop in the queue")
    }

    func testCursorDoesNotAdvanceWhenTheRowCannotBePersisted() throws {
        let dir = try TempDirectory()
        let outboxDir = try dir.child("outbox")
        let store = try OutboxStore(directory: outboxDir)
        // Make the next persist impossible: the directory the store writes into
        // is gone, which is what a full container or a failed write looks like.
        try FileManager.default.removeItem(at: outboxDir)

        let anchorsDir = try dir.child("anchors")
        let anchors = try AnchorStore(directory: anchorsDir)
        let source = ScriptedSource()
        source.queue(FetchResult(cursor: "c1", inserted: [makeRecord(1)], deleted: []), for: hrv)

        let collector = Collector(source: source, outbox: store, anchors: anchors, types: [hrv], clock: { t0 })
        XCTAssertThrowsError(try collector.collectOnce())

        let reopened = try AnchorStore(directory: anchorsDir)
        XCTAssertNil(
            reopened.cursor(for: hrv),
            "a cursor that moved past an unwritten row is a lost window"
        )
    }

    func testAuthorizationDeniedIsDiagnosableAndChangesNothing() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: try dir.child("outbox"))
        let anchorsDir = try dir.child("anchors")
        let anchors = try AnchorStore(directory: anchorsDir)
        let source = ScriptedSource()
        source.failure = .authorizationDenied

        let collector = Collector(source: source, outbox: store, anchors: anchors, types: [hrv], clock: { t0 })
        XCTAssertThrowsError(try collector.collectOnce()) { error in
            // The failure has to name itself: a revoked permission reported as
            // "no new data" is indistinguishable from a healthy empty day.
            XCTAssertEqual(error as? HealthSourceFailure, .authorizationDenied)
        }
        XCTAssertEqual(store.queueDepth, 0)
        XCTAssertNil(try AnchorStore(directory: anchorsDir).cursor(for: hrv))
    }

    func testUnreadableStoreIsNotAnEmptyFetch() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: try dir.child("outbox"))
        let anchorsDir = try dir.child("anchors")
        let anchors = try AnchorStore(directory: anchorsDir)
        let source = ScriptedSource()
        source.failure = .storeUnreadable

        let collector = Collector(source: source, outbox: store, anchors: anchors, types: [hrv], clock: { t0 })
        XCTAssertThrowsError(try collector.collectOnce()) { error in
            XCTAssertEqual(error as? HealthSourceFailure, .storeUnreadable)
        }

        XCTAssertEqual(store.queueDepth, 0)
        XCTAssertNil(
            try AnchorStore(directory: anchorsDir).cursor(for: hrv),
            "a locked device must not advance the cursor as if there were no new data"
        )
    }

    func testDeletionIsQueuedIndependentlyOfItsInsert() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: try dir.child("outbox"))
        let anchors = try AnchorStore(directory: try dir.child("anchors"))
        let record = makeRecord(1)
        let source = ScriptedSource()
        source.queue(
            FetchResult(cursor: "c1", inserted: [record], deleted: [makeDeletion(of: record)]),
            for: hrv
        )

        let collector = Collector(source: source, outbox: store, anchors: anchors, types: [hrv], clock: { t0 })
        let report = try collector.collectOnce()

        XCTAssertEqual(report.inserted, 1)
        XCTAssertEqual(report.deleted, 1)
        let kinds = Set(store.all.map { $0.payload.kind })
        XCTAssertEqual(kinds, [.insert, .delete])
    }

    func testSecondCollectIsIdempotentForAlreadyQueuedRows() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: try dir.child("outbox"))
        let anchors = try AnchorStore(directory: try dir.child("anchors"))
        let record = makeRecord(1)
        let source = ScriptedSource()
        // The same window arrives twice: the cursor write was lost, or the query
        // re-delivered. Neither may create a second queue row.
        source.queue(FetchResult(cursor: "c1", inserted: [record], deleted: []), for: hrv)
        source.queue(FetchResult(cursor: "c1", inserted: [record], deleted: []), for: hrv)

        let collector = Collector(source: source, outbox: store, anchors: anchors, types: [hrv], clock: { t0 })
        XCTAssertEqual(try collector.collectOnce().inserted, 1)
        let second = try collector.collectOnce()
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.duplicatesSkipped, 1)
        XCTAssertEqual(store.queueDepth, 1)
    }
}
