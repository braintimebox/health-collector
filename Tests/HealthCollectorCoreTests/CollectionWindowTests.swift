import XCTest
import HealthCollectorCore

/// The period a user picks in Manual is a filter on a read, never a way to move the
/// cursor. Moving a cursor to the window's edge is how a "filter" becomes data loss.
final class CollectionWindowTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private var now: Date {
        ISOTimestamp.date(from: "2026-11-23T12:00:00.000Z")!
    }

    private func offset(of window: CollectionWindow) throws -> Double {
        try XCTUnwrap(window.from).timeIntervalSince(now)
    }

    func testEachPeriodMapsToItsOwnLookback() throws {
        XCTAssertEqual(try offset(of: .make(period: .day, now: now, calendar: calendar)), -86_400, accuracy: 1)
        XCTAssertEqual(try offset(of: .make(period: .week, now: now, calendar: calendar)), -7 * 86_400, accuracy: 1)
        XCTAssertEqual(try offset(of: .make(period: .month, now: now, calendar: calendar)), -30 * 86_400, accuracy: 1)
        XCTAssertEqual(try offset(of: .make(period: .quarter, now: now, calendar: calendar)), -90 * 86_400, accuracy: 1)
    }

    func testAllHistoryHasNoLowerBound() {
        let window = CollectionWindow.make(period: .all, now: now, calendar: calendar)
        XCTAssertNil(window.from)
        XCTAssertTrue(window.isFullHistory)
        XCTAssertEqual(window.to, now)
    }

    func testWindowNeverEndsInTheFuture() {
        for period in CollectionPeriod.allCases {
            let window = CollectionWindow.make(period: period, now: now, calendar: calendar)
            XCTAssertLessThanOrEqual(window.to, now, "окно не может заканчиваться в будущем: \(period)")
            if let from = window.from {
                XCTAssertLessThan(from, window.to, "пустое окно превращает экспорт в тихий ноль: \(period)")
            }
        }
    }

    func testPeriodsAreStableAcrossTheDaylightSavingBoundary() throws {
        // 2026-03-29 is the European DST switch: a lookback measured in seconds
        // would drift by an hour, and a week would stop being a week.
        var warsaw = Calendar(identifier: .gregorian)
        warsaw.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        let springForward = ISOTimestamp.date(from: "2026-03-30T12:00:00.000Z")!
        let window = CollectionWindow.make(period: .week, now: springForward, calendar: warsaw)
        let from = try XCTUnwrap(window.from)
        let days = warsaw.dateComponents([.day], from: from, to: window.to).day
        XCTAssertEqual(days, 7, "неделя обязана остаться неделей через перевод стрелок")
    }
}
