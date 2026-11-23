import XCTest
import HealthCollectorCore

/// The client half of the measurement route: the request envelope the spec fixes,
/// and the reading of its answer. Everything here runs without a server, because
/// the questions are about shape and meaning, not transport.
final class MeasurementClientTests: XCTestCase {
    private let baseURL = URL(string: "https://collector.example.invalid")!

    private func payload() -> WireBatch {
        WireBatch(
            userID: "owner",
            batchID: "0f3c1a8e-batch",
            records: [makeRecord(1, user: "owner")],
            deletes: [makeDeletion(of: makeRecord(2, user: "owner"))]
        )
    }

    // MARK: Request

    func testRequestEnvelopeMatchesTheSpec() throws {
        let data = try MeasurementClient.requestBody(batch: payload())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["user_id"] as? String, "owner")
        XCTAssertEqual(json["batch_id"] as? String, "0f3c1a8e-batch")

        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        let record = try XCTUnwrap(records.first)
        let identity = try XCTUnwrap(record["identity"] as? [String: Any])
        XCTAssertEqual(identity["user_id"] as? String, "owner")
        XCTAssertNotNil(identity["record_id"])
        for key in ["type", "value", "unit", "start_date", "end_date", "time_zone", "source_name", "source_id"] {
            XCTAssertNotNil(record[key], "в конверте нет поля \(key)")
        }

        let deletes = try XCTUnwrap(json["deletes"] as? [[String: Any]])
        let deletion = try XCTUnwrap(deletes.first)
        XCTAssertNotNil(deletion["deleted_at"])
        XCTAssertNotNil((deletion["identity"] as? [String: Any])?["record_id"])
    }

    func testWireTimestampsAreUTCAndTheZoneTravelsSeparately() throws {
        let data = try MeasurementClient.requestBody(batch: payload())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let record = try XCTUnwrap((json["records"] as? [[String: Any]])?.first)

        let start = try XCTUnwrap(record["start_date"] as? String)
        let end = try XCTUnwrap(record["end_date"] as? String)
        XCTAssertTrue(ISOTimestamp.isUTC(start), "спека фиксирует start_date как ISO 8601 UTC: \(start)")
        XCTAssertTrue(ISOTimestamp.isUTC(end), "спека фиксирует end_date как ISO 8601 UTC: \(end)")
        XCTAssertEqual(record["time_zone"] as? String, "Europe/Warsaw")
        XCTAssertNotNil(ISOTimestamp.date(from: start))
    }

    func testRequestCarriesTokenAndRoute() throws {
        let request = try MeasurementClient.makeRequest(batch: payload(), baseURL: baseURL, token: "t0ken")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://collector.example.invalid/v1/measurements")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t0ken")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNotNil(request.httpBody)
    }

    // MARK: Response

    private func ackJSON(accepted: [String], rejected: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "batch_id": "0f3c1a8e-batch",
            "accepted": accepted,
            "rejected": rejected,
            "duplicates": 0,
            "server_time": "2026-11-23T10:40:00Z",
        ])
    }

    func testFullAckIsReadAsStored() throws {
        let id = makeRecord(1, user: "owner").identity.recordID
        let reply = HTTPReply(status: 200, body: ackJSON(accepted: [id], rejected: []))
        let ack = try MeasurementClient.decode(reply: reply)
        XCTAssertEqual(ack.accepted, [id])
        XCTAssertTrue(ack.rejected.isEmpty)
    }

    func testPartialSuccessKeepsBothArrays() throws {
        let good = makeRecord(1, user: "owner").identity.recordID
        let bad = makeRecord(2, user: "owner").identity.recordID
        let body = ackJSON(
            accepted: [good],
            rejected: [
                ["record_id": bad, "reason": "unit_mismatch", "permanent": true],
                ["record_id": "third", "reason": "storage_full", "permanent": false],
            ]
        )
        let ack = try MeasurementClient.decode(reply: HTTPReply(status: 200, body: body))

        XCTAssertEqual(ack.accepted, [good])
        XCTAssertEqual(ack.rejected.count, 2)
        XCTAssertEqual(ack.rejected.first?.recordID, bad)
        XCTAssertEqual(ack.rejected.first?.reason, "unit_mismatch")
        XCTAssertEqual(ack.rejected.first?.permanent, true)
        XCTAssertEqual(ack.rejected.last?.permanent, false)
    }

    func test200WithoutAcceptedIsUnconfirmedNotSuccess() throws {
        // The exact failure the outbox exists to catch: a server that answers OK
        // without naming what it stored.
        let body = try JSONSerialization.data(withJSONObject: ["batch_id": "x", "rejected": []])
        XCTAssertThrowsError(try MeasurementClient.decode(reply: HTTPReply(status: 200, body: body))) { error in
            guard let failure = error as? TransportFailure else {
                return XCTFail("ожидался TransportFailure, получено \(error)")
            }
            XCTAssertEqual(failure.kind, .malformedAck)
            XCTAssertEqual(RetryPolicy().classification(for: failure), .unconfirmed)
        }
    }

    func testGarbageBodyIsUnconfirmed() {
        let reply = HTTPReply(status: 200, body: Data("<html>502</html>".utf8))
        XCTAssertThrowsError(try MeasurementClient.decode(reply: reply)) { error in
            XCTAssertEqual((error as? TransportFailure)?.kind, .malformedAck)
        }
    }

    func testServerFailuresAreRetryableWithRetryAfter() {
        for status in [500, 503] {
            let reply = HTTPReply(status: status, retryAfter: 30, body: Data("busy".utf8))
            XCTAssertThrowsError(try MeasurementClient.decode(reply: reply)) { error in
                guard let failure = error as? TransportFailure else {
                    return XCTFail("ожидался TransportFailure")
                }
                XCTAssertEqual(failure.status, status)
                XCTAssertEqual(failure.retryAfter, 30)
                XCTAssertEqual(RetryPolicy().classification(for: failure), .retryable)
            }
        }
    }

    func testWholeBatchRejectionsDeadLetter() {
        // 400/413/422 mean the batch itself is unusable; the same payload will not
        // become valid by waiting.
        for status in [400, 413, 422] {
            let reply = HTTPReply(status: status, body: Data("bad".utf8))
            XCTAssertThrowsError(try MeasurementClient.decode(reply: reply)) { error in
                guard let failure = error as? TransportFailure else {
                    return XCTFail("ожидался TransportFailure")
                }
                XCTAssertEqual(RetryPolicy().classification(for: failure), .permanent)
            }
        }
    }

    func testCredentialProblemNeverDestroysData() {
        // A token is a thing that gets fixed, so 401/403 retry instead of
        // dead-lettering: a misconfigured token must not become lost measurements.
        for status in [401, 403] {
            let reply = HTTPReply(status: status, body: Data("unauthorized".utf8))
            XCTAssertThrowsError(try MeasurementClient.decode(reply: reply)) { error in
                guard let failure = error as? TransportFailure else {
                    return XCTFail("ожидался TransportFailure")
                }
                XCTAssertEqual(RetryPolicy().classification(for: failure), .retryable)
            }
        }
    }

    func testRecordOfAnotherUserIsCaughtBeforeSending() {
        // The batch is built by the engine from the store, so a mismatch means a bug
        // here — not a server verdict. It must not become a 401 that reads as a
        // credential problem.
        let batch = WireBatch(
            userID: "owner",
            batchID: "b",
            records: [makeRecord(1, user: "someone-else")],
            deletes: []
        )
        XCTAssertThrowsError(try MeasurementClient.requestBody(batch: batch)) { error in
            guard case let ClientError.identityMismatch(_, batchUser, recordUser) = error else {
                return XCTFail("ожидался identityMismatch, получено \(error)")
            }
            XCTAssertEqual(batchUser, "owner")
            XCTAssertEqual(recordUser, "someone-else")
        }
    }

    func testErrorTextIsShortEnoughToLog() {
        let long = String(repeating: "x", count: 5000)
        let reply = HTTPReply(status: 500, body: Data(long.utf8))
        XCTAssertThrowsError(try MeasurementClient.decode(reply: reply)) { error in
            let message = (error as? TransportFailure)?.message ?? ""
            XCTAssertLessThanOrEqual(message.count, 201, "в лог не должны попадать килобайты тела")
        }
    }
}
