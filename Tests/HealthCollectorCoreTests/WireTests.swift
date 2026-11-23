import XCTest
import HealthCollectorCore

/// The wire contract and the identity rule. A wrong key here duplicates data
/// forever; a wrong timestamp here moves a measurement into the wrong day.
final class WireTests: XCTestCase {
    func testWireContractCarriesSnakeCaseFieldsAndSourceIdentity() throws {
        let record = makeRecord(1)
        let batch = WireBatch(userID: "user-1", records: [record], deletes: [])
        let data = try WireCodec.encoder().encode(batch)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["user_id"] as? String, "user-1")

        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        let first = try XCTUnwrap(records.first)
        for key in ["type", "value", "unit", "start_date", "end_date", "time_zone", "source_name", "source_id"] {
            XCTAssertNotNil(first[key], "wire field \(key) is missing")
        }
        let identity = try XCTUnwrap(first["identity"] as? [String: Any])
        XCTAssertEqual(identity["record_id"] as? String, record.identity.recordID)
        XCTAssertEqual(identity["user_id"] as? String, "user-1")

        let decoded = try WireCodec.decoder().decode(WireBatch.self, from: data)
        XCTAssertEqual(decoded, batch)
        XCTAssertEqual(decoded.records.first?.value, 65.4)
    }

    func testDeletesTravelInTheirOwnArray() throws {
        let record = makeRecord(1)
        let batch = WireBatch(userID: "user-1", records: [], deletes: [makeDeletion(of: record)])
        let data = try WireCodec.encoder().encode(batch)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual((json["records"] as? [Any])?.count, 0)
        let deletes = try XCTUnwrap(json["deletes"] as? [[String: Any]])
        XCTAssertEqual(deletes.count, 1)
        XCTAssertNotNil(deletes.first?["deleted_at"])
    }

    func testTimestampKeepsTheOffsetAndTheInstant() throws {
        let string = "2026-11-23T07:30:00.000+01:00"
        let date = try XCTUnwrap(ISOTimestamp.date(from: string))
        let utc = try XCTUnwrap(ISOTimestamp.date(from: "2026-11-23T06:30:00.000Z"))
        XCTAssertEqual(date.timeIntervalSince1970, utc.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(ISOTimestamp.string(from: date, timeZoneIdentifier: "Europe/Warsaw"), string)
    }

    func testTimestampWithoutFractionalSecondsStillParses() throws {
        let date = try XCTUnwrap(ISOTimestamp.date(from: "2026-11-23T07:30:00+01:00"))
        let utc = try XCTUnwrap(ISOTimestamp.date(from: "2026-11-23T06:30:00.000Z"))
        XCTAssertEqual(date.timeIntervalSince1970, utc.timeIntervalSince1970, accuracy: 0.001)
    }

    func testIdentityIsTenantAndRecordOnly() {
        let measurement = makeRecord(1, type: "heart_rate_variability", unit: "ms", value: 65.4)
        // Same sample, re-classified and re-unit-ed by a later schema decision.
        let reclassified = makeRecord(1, type: "hrv_sdnn", unit: "ms", value: 66.0)

        XCTAssertEqual(measurement.identity.canonicalKey, reclassified.identity.canonicalKey)
        XCTAssertEqual(
            measurement.identity.canonicalKey,
            "user-1:" + measurement.identity.recordID.lowercased(),
            "type, unit and value are attributes, never key parts"
        )
    }

    func testIdentityIsScopedPerUser() {
        let mine = makeRecord(1, user: "user-1")
        let theirs = makeRecord(1, user: "user-2")
        XCTAssertNotEqual(mine.identity.canonicalKey, theirs.identity.canonicalKey)
    }

    func testAnchorFileKeepsRawTypeKeys() throws {
        // The anchors file is keyed by data type. A snake-case decode strategy
        // applied here would rewrite `heart_rate_variability` on read.
        let dir = try TempDirectory()
        let anchors = try AnchorStore(directory: dir.url)
        try anchors.save("anchor-1", for: "heart_rate_variability")

        let reopened = try AnchorStore(directory: dir.url)
        XCTAssertEqual(reopened.cursor(for: "heart_rate_variability"), "anchor-1")
        XCTAssertEqual(reopened.types, ["heart_rate_variability"])
    }

    func testNilCursorMeansFullHistoryAndIsRecoverable() throws {
        let dir = try TempDirectory()
        let anchors = try AnchorStore(directory: dir.url)
        XCTAssertNil(anchors.cursor(for: "heart_rate_variability"))

        try anchors.save("anchor-1", for: "heart_rate_variability")
        XCTAssertFalse(anchors.isFullHistory(for: "heart_rate_variability"))

        try anchors.save(nil, for: "heart_rate_variability")
        XCTAssertTrue(anchors.isFullHistory(for: "heart_rate_variability"))
        XCTAssertNil(try AnchorStore(directory: dir.url).cursor(for: "heart_rate_variability"))
    }
}
