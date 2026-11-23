import XCTest
import HealthCollectorCore

/// Matrix rows 1, 4, 5 of the acceptance table: nothing may be lost by a process
/// ending, and an acked row must never be sent again.
final class DurabilityTests: XCTestCase {
    func testRowsSurviveProcessDeath() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: dir.url)
        XCTAssertTrue(try store.enqueue(.insert(makeRecord(1)), now: t0))
        XCTAssertTrue(try store.enqueue(.insert(makeRecord(2)), now: t0.addingTimeInterval(1)))

        // A new instance reading the same directory is what a relaunch actually is.
        let reopened = try OutboxStore(directory: dir.url)
        XCTAssertEqual(reopened.pendingCount, 2)
        XCTAssertEqual(
            reopened.all.map { $0.payload.identity.recordID }.sorted(),
            store.all.map { $0.payload.identity.recordID }.sorted()
        )
        XCTAssertEqual(
            reopened.all[0].createdAt.timeIntervalSince1970,
            store.all[0].createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testInflightRowsAreRequeuedOnLaunch() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: dir.url)
        try store.enqueue(.insert(makeRecord(1)), now: t0)
        let claimed = try store.claim(now: t0, limit: 10)
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(store.inflightCount, 1)

        // The process died mid-flight: nothing resets inflight except a launch.
        let reopened = try OutboxStore(directory: dir.url)
        XCTAssertEqual(reopened.inflightCount, 0)
        XCTAssertEqual(reopened.pendingCount, 1)
        XCTAssertEqual(try reopened.claim(now: t0.addingTimeInterval(1), limit: 10).count, 1)
    }

    func testAckedRowsAreNotResent() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: dir.url)
        let server = FakeServer()
        try store.enqueue(.insert(makeRecord(1)), now: t0)
        try store.enqueue(.insert(makeRecord(2)), now: t0)

        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        let first = try engine.drain(now: t0)
        XCTAssertEqual(first.accepted, 2)

        let second = try engine.drain(now: t0.addingTimeInterval(30))
        XCTAssertEqual(second.claimed, 0, "an acked row must not be claimed again")
        XCTAssertEqual(server.batches.count, 1)
        XCTAssertEqual(server.rowCount, 2)
    }

    func testDuplicateEnqueueIsRefused() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: dir.url)
        XCTAssertTrue(try store.enqueue(.insert(makeRecord(1)), now: t0))
        XCTAssertFalse(try store.enqueue(.insert(makeRecord(1)), now: t0.addingTimeInterval(5)))
        XCTAssertEqual(store.pendingCount, 1)
    }

    func testQueueIsEmptyOnlyWhenItIsEmpty() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: dir.url)
        XCTAssertEqual(store.queueDepth, 0)
        XCTAssertNil(store.oldestPendingAge(now: t0))
        try store.enqueue(.insert(makeRecord(1)), now: t0)
        XCTAssertEqual(store.queueDepth, 1)
        XCTAssertEqual(try XCTUnwrap(store.oldestPendingAge(now: t0.addingTimeInterval(3600))), 3600, accuracy: 0.001)
    }
}
