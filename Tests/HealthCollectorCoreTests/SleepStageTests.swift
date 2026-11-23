import XCTest
@testable import HealthCollectorCore

/// The stage must reach the wire, otherwise every sleep row is "6.2 hours of
/// something" and recovery analysis averages deep, REM and awake together.
final class SleepStageTests: XCTestCase {

    func test_documentedCategoryValuesMapToDistinctWireTypes() {
        let expected: [Int: String] = [
            0: "sleep_in_bed",
            1: "sleep_asleep",
            2: "sleep_awake",
            3: "sleep_core",
            4: "sleep_deep",
            5: "sleep_rem",
            6: "sleep_unspecified",
        ]
        for (raw, wire) in expected {
            XCTAssertEqual(SleepStage.from(categoryValue: raw).wireType, wire, "raw value \(raw)")
        }
        XCTAssertEqual(Set(expected.values).count, expected.count, "every stage is distinct on the wire")
    }

    func test_unknownValueBecomesUnspecifiedInsteadOfDroppingSleep() {
        XCTAssertEqual(SleepStage.from(categoryValue: 99), .unspecified)
        XCTAssertEqual(SleepStage.from(categoryValue: -1), .unspecified)
    }

    func test_allWireTypesAreDeclaredForTheServer() {
        XCTAssertEqual(SleepStage.wireTypes.count, SleepStage.allCases.count)
        XCTAssertTrue(SleepStage.wireTypes.allSatisfy { $0.hasPrefix("sleep_") })
        XCTAssertFalse(SleepStage.wireTypes.contains("sleep_analysis"),
                       "the aggregate type must not be used for a stage row")
    }
}
