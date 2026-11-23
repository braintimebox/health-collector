import XCTest
import HealthCollectorCore

/// A transport with the shape iOS actually gives us: the upload reads a file, and
/// the answer comes back after the app may have been suspended.
final class FakeFileTransport: FileBackedTransport {
    private let server: FakeServer
    private(set) var filesSeen: [URL] = []
    private(set) var fileExistedAtSend: [Bool] = []
    private(set) var filesWereEmpty: [Bool] = []
    var failure: TransportFailure?

    init(server: FakeServer) {
        self.server = server
    }

    func send(_ batch: WireBatch) throws -> ServerAck {
        if let failure { throw failure }
        return try server.send(batch)
    }

    func send(fileAt url: URL, userID: String) throws -> ServerAck {
        filesSeen.append(url)
        fileExistedAtSend.append(FileManager.default.fileExists(atPath: url.path))
        let data = (try? Data(contentsOf: url)) ?? Data()
        filesWereEmpty.append(data.isEmpty)
        if let failure { throw failure }
        let batch = try WireCodec.decoder().decode(WireBatch.self, from: data)
        return try server.send(batch)
    }
}

/// The two obligations of `handleEventsForBackgroundURLSession`, plus the file the
/// background upload reads: the batch must exist on disk before the transfer
/// starts, and the wake must arm the next one.
final class TransferTests: XCTestCase {
    private func makeEngine(
        store: OutboxStore,
        transport: FileBackedTransport,
        spool: BatchSpool,
        batchLimit: Int = 500
    ) -> SyncEngine {
        SyncEngine(userID: "user-1", store: store, transport: transport, batchLimit: batchLimit, spool: spool)
    }

    func testBatchIsOnDiskBeforeTheUploadStarts() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: try dir.child("outbox"))
        let spool = try BatchSpool(directory: try dir.child("spool"))
        let server = FakeServer()
        let transport = FakeFileTransport(server: server)

        try store.enqueue(.insert(makeRecord(1)), now: t0)
        try store.enqueue(.insert(makeRecord(2)), now: t0)

        let engine = makeEngine(store: store, transport: transport, spool: spool)
        let report = try engine.drain(now: t0)

        XCTAssertEqual(report.accepted, 2)
        XCTAssertEqual(transport.filesSeen.count, 1)
        XCTAssertEqual(transport.fileExistedAtSend, [true], "the upload must read an existing file")
        XCTAssertEqual(transport.filesWereEmpty, [false])
        XCTAssertEqual(server.rowCount, 2)
        XCTAssertTrue(spool.pendingFiles().isEmpty, "a settled batch leaves no file behind")
    }

    func testWakeSettlesTheFinishedUploadAndArmsTheNextBatch() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: try dir.child("outbox"))
        let spool = try BatchSpool(directory: try dir.child("spool"))
        let server = FakeServer()
        let transport = FakeFileTransport(server: server)

        for index in 1...3 {
            try store.enqueue(.insert(makeRecord(index)), now: t0)
        }

        // Two rows go into the first file; the third waits for its own.
        let engine = makeEngine(store: store, transport: transport, spool: spool, batchLimit: 2)
        let first = try XCTUnwrap(try engine.spoolNextBatch(now: t0))
        let firstBatch = try spool.read(at: first)
        XCTAssertEqual(firstBatch.records.count, 2)
        XCTAssertEqual(store.inflightCount, 2)

        // iOS wakes the app because that upload finished. The ack here stands in for
        // the server's answer, carried by the session delegate — which is why this
        // test asserts on queue state and files, not on the fake server: the transfer
        // happened outside this process and only the answer comes back.
        let wake = BackgroundWake(engine: engine)
        let accepted = firstBatch.records.map { $0.identity.recordID }
        let plan = try wake.handleEvent(
            now: t0.addingTimeInterval(1),
            completed: [CompletedUpload(fileAt: first, ack: ServerAck(accepted: accepted))]
        )

        XCTAssertEqual(plan.accepted, 2)
        XCTAssertEqual(store.ackedCount, 2)
        // The two finished rows are settled; the third is already claimed by the
        // batch the wake has just armed, so exactly one row is in flight.
        XCTAssertEqual(store.inflightCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "a settled file is removed")

        // The trigger has already fired. Without this second file the pipeline stops
        // here with one row still queued.
        let next = try XCTUnwrap(plan.nextBatchFile, "the wake must arm the next batch itself")
        let nextBatch = try spool.read(at: next)
        XCTAssertEqual(nextBatch.records.count, 1)

        let finalPlan = try wake.handleEvent(
            now: t0.addingTimeInterval(2),
            completed: [CompletedUpload(fileAt: next, ack: ServerAck(accepted: nextBatch.records.map { $0.identity.recordID }))]
        )
        XCTAssertEqual(finalPlan.accepted, 1)
        XCTAssertNil(finalPlan.nextBatchFile)
        XCTAssertEqual(store.queueDepth, 0)
        XCTAssertTrue(spool.pendingFiles().isEmpty)
    }

    func testSpooledBatchSurvivesRelaunchAndIsResentFromTheStore() throws {
        let dir = try TempDirectory()
        let outboxDir = try dir.child("outbox")
        let store = try OutboxStore(directory: outboxDir)
        let spool = try BatchSpool(directory: try dir.child("spool"))
        let server = FakeServer()
        let transport = FakeFileTransport(server: server)

        try store.enqueue(.insert(makeRecord(1)), now: t0)
        let engine = makeEngine(store: store, transport: transport, spool: spool)
        let file = try XCTUnwrap(try engine.spoolNextBatch(now: t0))

        // The process dies before the upload finishes; the next launch reads the
        // same outbox and finds the row inflight, not sent.
        let relaunched = try OutboxStore(directory: outboxDir)
        XCTAssertEqual(relaunched.pendingCount, 1)

        let secondEngine = makeEngine(store: relaunched, transport: transport, spool: spool)
        let report = try secondEngine.drain(now: t0.addingTimeInterval(60))
        XCTAssertEqual(report.accepted, 1)
        XCTAssertEqual(server.rowCount, 1, "one row, not a duplicate of the orphaned batch")

        // A late answer for the orphaned file settles nothing and breaks nothing.
        let orphanReport = try secondEngine.settleSpooled(
            fileAt: file,
            ack: ServerAck(accepted: [makeRecord(1).identity.recordID]),
            now: t0.addingTimeInterval(120)
        )
        XCTAssertEqual(orphanReport.claimed, 0)
        XCTAssertEqual(server.rowCount, 1)
    }

    func testSpoolIsNotUsedWhenTheTransportSendsFromMemory() throws {
        let dir = try TempDirectory()
        let store = try OutboxStore(directory: try dir.child("outbox"))
        let spool = try BatchSpool(directory: try dir.child("spool"))
        let server = FakeServer()

        try store.enqueue(.insert(makeRecord(1)), now: t0)
        // A plain transport keeps the in-memory path: spooling is only correct for
        // a transport that reads the file.
        let engine = SyncEngine(userID: "user-1", store: store, transport: server, spool: spool)
        XCTAssertNil(try engine.spoolNextBatch(now: t0))
        XCTAssertEqual(try engine.drain(now: t0).accepted, 1)
        XCTAssertTrue(spool.pendingFiles().isEmpty)
    }
}
