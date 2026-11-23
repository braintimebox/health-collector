import XCTest
import HealthCollectorCore

/// Matrix rows 1, 2, 3, 7, 9, 10: offline retention, drain on recovery, backoff,
/// partial ack, an unreadable answer, and dead-lettering.
final class SyncTests: XCTestCase {
    private func makeStore(_ dir: TempDirectory) throws -> OutboxStore {
        try OutboxStore(directory: dir.url)
    }

    func testNetworkDownKeepsRowsQueued() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let server = FakeServer()
        server.failure = TransportFailure(kind: .transport, message: "no network")

        try store.enqueue(.insert(makeRecord(1)), now: t0)
        try store.enqueue(.insert(makeRecord(2)), now: t0.addingTimeInterval(1))

        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        // Both rows are due now: the second was queued a second after the first.
        let report = try engine.drain(now: t0.addingTimeInterval(2))

        XCTAssertEqual(report.claimed, 2)
        XCTAssertEqual(report.accepted, 0)
        XCTAssertEqual(report.retried, 2)
        XCTAssertEqual(store.pendingCount, 2, "rows must stay queued when the network is down")
        XCTAssertEqual(store.all[0].attempt, 1)
        XCTAssertEqual(
            store.all[0].nextAttemptAt.timeIntervalSince1970,
            t0.addingTimeInterval(4).timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(server.rowCount, 0)
    }

    func testQueueDrainsInOrderWhenNetworkReturns() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let server = FakeServer()
        let first = makeRecord(1)
        let second = makeRecord(2)

        server.failure = TransportFailure(kind: .timeout, message: "timed out")
        try store.enqueue(.insert(first), now: t0)
        try store.enqueue(.insert(second), now: t0.addingTimeInterval(1))
        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        _ = try engine.drain(now: t0)

        server.failure = nil
        let report = try engine.drain(now: t0.addingTimeInterval(5))

        XCTAssertEqual(report.accepted, 2)
        XCTAssertEqual(server.rowCount, 2)
        XCTAssertEqual(
            server.batches.last?.records.map { $0.identity.recordID },
            [first.identity.recordID, second.identity.recordID],
            "a backlog drains oldest first"
        )
        XCTAssertEqual(store.queueDepth, 0)
    }

    func testBackoffGrowsAndIsCapped() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let server = FakeServer()
        server.failure = TransportFailure(kind: .http, status: 500, message: "worker is down")
        try store.enqueue(.insert(makeRecord(1)), now: t0)

        let engine = SyncEngine(userID: "user-1", store: store, transport: server)

        _ = try engine.drain(now: t0)
        XCTAssertEqual(try XCTUnwrap(store.all.first).attempt, 1)
        XCTAssertEqual(
            try XCTUnwrap(store.all.first).nextAttemptAt.timeIntervalSince1970,
            t0.addingTimeInterval(2).timeIntervalSince1970,
            accuracy: 0.001
        )

        _ = try engine.drain(now: t0.addingTimeInterval(2))
        XCTAssertEqual(try XCTUnwrap(store.all.first).attempt, 2)
        XCTAssertEqual(
            try XCTUnwrap(store.all.first).nextAttemptAt.timeIntervalSince1970,
            t0.addingTimeInterval(6).timeIntervalSince1970,
            accuracy: 0.001
        )

        _ = try engine.drain(now: t0.addingTimeInterval(6))
        XCTAssertEqual(try XCTUnwrap(store.all.first).attempt, 3)
        XCTAssertEqual(
            try XCTUnwrap(store.all.first).nextAttemptAt.timeIntervalSince1970,
            t0.addingTimeInterval(14).timeIntervalSince1970,
            accuracy: 0.001
        )

        let policy = RetryPolicy()
        XCTAssertEqual(policy.delay(forAttempt: 40, jitter: 0.5), policy.cap, accuracy: 0.001)
    }

    func testRetryAfterIsHonoured() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let server = FakeServer()
        server.failure = TransportFailure(kind: .http, status: 429, retryAfter: 60, message: "slow down")
        try store.enqueue(.insert(makeRecord(1)), now: t0)

        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        _ = try engine.drain(now: t0)

        XCTAssertEqual(
            try XCTUnwrap(store.all.first).nextAttemptAt.timeIntervalSince1970,
            t0.addingTimeInterval(60).timeIntervalSince1970,
            accuracy: 0.001,
            "Retry-After beats the local schedule when it is longer"
        )
    }

    func testClientErrorIsDeadLetteredNotRetriedForever() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let server = FakeServer()
        server.failure = TransportFailure(kind: .http, status: 400, message: "empty_metrics")
        try store.enqueue(.insert(makeRecord(1)), now: t0)

        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        let report = try engine.drain(now: t0)

        XCTAssertEqual(report.deadLettered, 1)
        XCTAssertEqual(store.deadCount, 1)
        XCTAssertEqual(store.pendingCount, 0)

        let second = try engine.drain(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(second.claimed, 0, "a 4xx payload will not become valid by waiting")
    }

    func testFailureClassification() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.classification(for: TransportFailure(kind: .transport, message: "")), .retryable)
        XCTAssertEqual(policy.classification(for: TransportFailure(kind: .timeout, message: "")), .retryable)
        XCTAssertEqual(policy.classification(for: TransportFailure(kind: .http, status: 500, message: "")), .retryable)
        XCTAssertEqual(policy.classification(for: TransportFailure(kind: .http, status: 503, message: "")), .retryable)
        XCTAssertEqual(policy.classification(for: TransportFailure(kind: .http, status: 408, message: "")), .retryable)
        XCTAssertEqual(policy.classification(for: TransportFailure(kind: .http, status: 429, message: "")), .retryable)
        XCTAssertEqual(policy.classification(for: TransportFailure(kind: .http, status: 401, message: "")), .permanent)
        XCTAssertEqual(policy.classification(for: TransportFailure(kind: .http, status: 404, message: "")), .permanent)
        XCTAssertEqual(policy.classification(for: TransportFailure(kind: .malformedAck, message: "")), .unconfirmed)
    }

    func testPartialAckResendsOnlyUnacked() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let server = FakeServer()
        try store.enqueue(.insert(makeRecord(1)), now: t0)
        try store.enqueue(.insert(makeRecord(2)), now: t0.addingTimeInterval(1))
        try store.enqueue(.insert(makeRecord(3)), now: t0.addingTimeInterval(2))

        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        server.ackMode = .firstOnly
        let first = try engine.drain(now: t0.addingTimeInterval(10))

        XCTAssertEqual(first.accepted, 1)
        XCTAssertEqual(first.retried, 2)
        XCTAssertEqual(store.pendingCount, 2)
        XCTAssertEqual(store.ackedCount, 1)

        server.ackMode = .all
        let second = try engine.drain(now: t0.addingTimeInterval(13))

        XCTAssertEqual(second.accepted, 2)
        XCTAssertEqual(store.queueDepth, 0)
        XCTAssertEqual(server.batches.count, 2)
        XCTAssertEqual(server.rowCount, 3, "resending the unacked rows must not duplicate the stored ones")
    }

    func testUnreadableAckIsUnconfirmed() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let server = FakeServer()
        try store.enqueue(.insert(makeRecord(1)), now: t0)
        try store.enqueue(.insert(makeRecord(2)), now: t0.addingTimeInterval(1))

        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        server.ackMode = .unparseable
        let report = try engine.drain(now: t0.addingTimeInterval(1))

        XCTAssertEqual(report.unconfirmed, 2)
        XCTAssertEqual(report.accepted, 0)
        XCTAssertEqual(store.pendingCount, 2)
        XCTAssertEqual(try XCTUnwrap(store.all.first).attempt, 0, "an unreadable answer is not a failed attempt")
        XCTAssertEqual(
            try XCTUnwrap(store.all.first).nextAttemptAt.timeIntervalSince1970,
            t0.addingTimeInterval(1).timeIntervalSince1970,
            accuracy: 0.001,
            "and it is retried immediately, because the server may well have stored it"
        )

        server.ackMode = .all
        let second = try engine.drain(now: t0.addingTimeInterval(2))
        XCTAssertEqual(second.accepted, 2)
        XCTAssertEqual(server.rowCount, 2, "idempotency makes the resend free")
    }

    func testSilenceIsNotCalledHealthy() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let anchors = try AnchorStore(directory: try dir.child("anchors"))
        let server = FakeServer()
        try store.enqueue(.insert(makeRecord(1)), now: t0)

        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        _ = try engine.drain(now: t0)

        let fresh = CollectorStatus.make(store: store, anchors: anchors, types: [], now: t0.addingTimeInterval(3600))
        XCTAssertEqual(fresh.verdict, .healthy)
        XCTAssertNotNil(fresh.lastNewRowAt, "health needs a recent row, not just a recent run")

        // Nothing new for a day and a half. From inside the app this is exactly what
        // a revoked read permission looks like — HealthKit answers like an empty day
        // — so it must not be reported as health.
        let silent = CollectorStatus.make(store: store, anchors: anchors, types: [], now: t0.addingTimeInterval(40 * 3600))
        XCTAssertEqual(silent.verdict, .degraded)
        XCTAssertTrue(silent.diagnosticText(appVersion: "0.1.0", apiVersion: "1").contains("Status: DEGRADED"))
    }

    func testStatusComesFromTheStore() throws {
        let dir = try TempDirectory()
        let store = try makeStore(dir)
        let anchorsDir = try dir.child("anchors")
        let anchors = try AnchorStore(directory: anchorsDir)
        let server = FakeServer()

        try store.enqueue(.insert(makeRecord(1)), now: t0)

        let late = CollectorStatus.make(
            store: store,
            anchors: anchors,
            permissions: .partial,
            backgroundDelivery: .enabled,
            types: ["heart_rate_variability"],
            now: t0.addingTimeInterval(7 * 3600)
        )
        XCTAssertEqual(late.verdict, .degraded)
        XCTAssertEqual(late.queueDepth, 1)
        XCTAssertNil(late.lastSuccessAt)
        XCTAssertEqual(late.fullHistoryTypes, ["heart_rate_variability"])

        let stalled = CollectorStatus.make(store: store, anchors: anchors, types: [], now: t0.addingTimeInterval(25 * 3600))
        XCTAssertEqual(stalled.verdict, .stalled)

        let engine = SyncEngine(userID: "user-1", store: store, transport: server)
        _ = try engine.drain(now: t0.addingTimeInterval(26 * 3600))

        let healthy = CollectorStatus.make(store: store, anchors: anchors, types: [], now: t0.addingTimeInterval(26 * 3600))
        XCTAssertEqual(healthy.verdict, .healthy)
        XCTAssertNotNil(healthy.lastSuccessAt)
        XCTAssertEqual(healthy.queueDepth, 0)
        XCTAssertTrue(healthy.diagnosticText(appVersion: "0.1.0", apiVersion: "1").contains("Status: HEALTHY"))
    }
}
