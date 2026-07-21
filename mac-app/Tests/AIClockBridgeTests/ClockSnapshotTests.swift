import XCTest
@testable import AIClockBridge

final class ClockSnapshotTests: XCTestCase {
    func testSanFranciscoStandardTime() {
        let value = snapshot(year: 2026, month: 1, day: 15, hour: 12)
        XCTAssertEqual(value.time, "04:00:00")
        XCTAssertEqual(value.date, "2026-01-15")
        XCTAssertEqual(value.weekday, "THU")
    }

    func testSanFranciscoDaylightSavingTime() {
        let value = snapshot(year: 2026, month: 7, day: 15, hour: 12)
        XCTAssertEqual(value.time, "05:00:00")
        XCTAssertEqual(value.date, "2026-07-15")
        XCTAssertEqual(value.weekday, "WED")
    }

    func testPayloadKeepsLegacyFieldsAndLabelsSanFranciscoFields() throws {
        let value = snapshot(year: 2026, month: 7, day: 15, hour: 12)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: value.jsonData()) as? [String: String])
        XCTAssertEqual(json["zone"], "America/Los_Angeles")
        XCTAssertEqual(json["zone_time"], "05:00:00")
        XCTAssertEqual(json["zone_date"], "2026-07-15")
        XCTAssertEqual(json["zone_weekday"], "WED")
        XCTAssertNotNil(json["time"])
        XCTAssertNotNil(json["date"])
        XCTAssertNotNil(json["weekday"])
    }

    private func snapshot(year: Int, month: Int, day: Int, hour: Int) -> ClockSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let value = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                       hour: hour, minute: 0, second: 0))!
        return ClockSnapshot.current(at: value)
    }
}
