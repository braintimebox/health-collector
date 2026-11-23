import XCTest
@testable import HealthCollectorCore

/// Regression tests for the findings of the independent review of fecdad8.
/// Every case names the bug it locks down: BUG-01, BUG-02, BUG-03, cleanup,
/// and the concurrency model. A green run here means the four defects cannot
/// come back without a red one.
final class ReviewRegressionTests: XCTestCase {

    private func makeStore(_ dir: TempDirectory) throws -> OutboxStore {
        try OutboxStore(directory: try dir.child("outbox"))
    }

    // MARK: BUG-01 — oldestPendingAge must report the OLDEST row

    func test_BUG01_oldestPendingAgeReportsTheOldestRowNotTheFreshest() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        try store.enqueue(.insert(makeRecord(1)), now: t0)                       // 3600 s old
        try store.enqueue(.insert(makeRecord(2)), now: t0.addingTimeInterval(3000)) // 600 s old
        try store.enqueue(.insert(makeRecord(3)), now: t0.addingTimeInterval(3500)) // 100 s old

        let age = try XCTUnwrap(store.oldestPendingAge(now: t0.addingTimeInterval(3600)))
        XCTAssertEqual(age, 3600, accuracy: 0.001,
                       "the queue has been stuck for an hour; min() reported 100 s and called it healthy")
    }

    func test_BUG01_reportsNilWhenNothingIsOutstanding() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        try store.enqueue(.insert(makeRecord(1)), now: t0)
        try store.settle([store.all[0].key: .accepted], now: t0)
        try store.pruneAcked(keeping: 0)
        XCTAssertNil(store.oldestPendingAge(now: t0.addingTimeInterval(10)))
    }

    // MARK: BUG-02 — unconfirmed acks back off, and the backoff is bounded

    func test_BUG02_unconfirmedBackoffGrowsAndIsCapped() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let server = FakeServer()
        try store.enqueue(.insert(makeRecord(1)), now: t0)

        let policy = RetryPolicy(baseDelay: 10, multiplier: 4, cap: 60, jitterFraction: 0)
        let engine = SyncEngine(userID: "user-1", store: store, transport: server, policy: policy)
        server.ackMode = .unparseable

        var now = t0
        var delays: [TimeInterval] = []
        for _ in 0..<5 {
            _ = try engine.drain(now: now)
            let row = try XCTUnwrap(store.all.first)
            delays.append(row.nextAttemptAt.timeIntervalSince(now))
            now = row.nextAttemptAt.addingTimeInterval(1)
        }

        XCTAssertEqual(delays, [10, 40, 60, 60, 60],
                       "4x growth from 10 s clamped at the 60 s cap; a tight loop would be all zeros")
        XCTAssertEqual(store.all.first?.state, .pending, "unconfirmed never dead-letters")
    }

    // MARK: BUG-03 — the ack is operation-aware

    func test_BUG03_insertAndDeleteOfOneIdentityNeverShareABatch() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let record = makeRecord(1)
        try store.enqueue(.insert(record), now: t0)
        try store.enqueue(.delete(makeDeletion(of: record)), now: t0.addingTimeInterval(1))
        XCTAssertEqual(store.queueDepth, 2)

        let claimed = try store.claim(now: t0.addingTimeInterval(10), limit: 50)
        XCTAssertEqual(claimed.count, 1,
                       "one server ack can only answer for one operation on this identity")
        XCTAssertEqual(claimed[0].payload.kind, .insert, "oldest first")

        let second = try store.claim(now: t0.addingTimeInterval(11), limit: 50)
        XCTAssertEqual(second.count, 1, "the delete goes out in the next batch")
        XCTAssertEqual(second[0].payload.kind, .delete)
    }

    func test_BUG03_oneAckCannotConfirmBothOperations() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let record = makeRecord(1)
        try store.enqueue(.insert(record), now: t0)
        try store.enqueue(.delete(makeDeletion(of: record)), now: t0.addingTimeInterval(1))

        let server = FakeServer()
        server.ackMode = .all
        let engine = SyncEngine(userID: "user-1", store: store, transport: server)

        // First drain: only the insert is in the wire batch, so its ack cannot
        // silently confirm the delete that shares the same record_id.
        let first = try engine.drain(now: t0.addingTimeInterval(10))
        XCTAssertEqual(first.claimed, 1, "one operation per identity per batch")
        XCTAssertEqual(first.accepted, 1)
        XCTAssertEqual(server.batches[0].deletes.count, 0, "the delete must not ride along")

        // Second drain: the delete goes out on its own and is confirmed by its own ack.
        let second = try engine.drain(now: t0.addingTimeInterval(20))
        XCTAssertEqual(second.claimed, 1)
        XCTAssertEqual(second.accepted, 1)
        XCTAssertEqual(server.batches[1].deletes.count, 1)
        XCTAssertEqual(store.queueDepth, 0)
    }

    // MARK: Cleanup of acked rows

    func test_pruneAckedKeepsARecentTailAndDropsTheRest() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        for index in 0..<10 {
            try store.enqueue(.insert(makeRecord(index)), now: t0.addingTimeInterval(Double(index)))
        }
        let decisions = Dictionary(uniqueKeysWithValues: store.all.map { ($0.key, Settlement.accepted) })
        try store.settle(decisions, now: t0.addingTimeInterval(100))
        XCTAssertEqual(store.ackedCount, 10)

        try store.pruneAcked(keeping: 3)
        XCTAssertEqual(store.ackedCount, 3, "history is the server's job; the queue keeps a tail for diagnostics")
        let survivors = Set(store.all.map { $0.createdAt })
        XCTAssertTrue(survivors.contains(t0.addingTimeInterval(9)), "the newest row is kept")
        XCTAssertFalse(survivors.contains(t0), "the oldest acked row is dropped")
    }

    func test_ackedRowsDoNotGrowForeverAcrossDrains() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let server = FakeServer()
        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        server.ackMode = .all

        for index in 0..<250 {
            try store.enqueue(.insert(makeRecord(index)), now: t0.addingTimeInterval(Double(index)))
        }
        _ = try engine.drain(now: t0.addingTimeInterval(1000))
        XCTAssertLessThanOrEqual(store.ackedCount, 200,
                                 "an unpruned queue grows with every successful send")
        XCTAssertEqual(server.rowCount, 250)
    }

    // MARK: Concurrency model

    func test_concurrentEnqueuesFromManyThreadsLoseNothing() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let threads = 8
        let perThread = 25
        let group = DispatchGroup()
        let failures = NSMutableArray()
        let lock = NSLock()

        for thread in 0..<threads {
            DispatchQueue.global().async(group: group) {
                for index in 0..<perThread {
                    do {
                        try store.enqueue(.insert(makeRecord(thread * 1000 + index)), now: t0)
                    } catch {
                        lock.lock(); failures.add("\(error)"); lock.unlock()
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        XCTAssertEqual(failures.count, 0, "enqueue threw under contention: \(failures)")
        XCTAssertEqual(store.pendingCount, threads * perThread,
                       "every row must survive; a lost row is lost health data")

        // and the file on disk agrees with the in-memory queue
        let reopened = try OutboxStore(directory: dir.url.appendingPathComponent("outbox"))
        XCTAssertEqual(reopened.pendingCount, threads * perThread)
    }

    func test_anchorStoreIsSafeToReadWhileWriting() throws {
        let dir = try TempDirectory()
        let anchors = try AnchorStore(directory: try dir.child("anchors"))
        let group = DispatchGroup()
        for index in 0..<50 {
            DispatchQueue.global().async(group: group) {
                try? anchors.save("cursor-\(index)", for: "type_\(index)")
            }
            DispatchQueue.global().async(group: group) {
                _ = anchors.cursor(for: "type_\(index)")
                _ = anchors.types
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(anchors.types.count, 50)
    }
}
