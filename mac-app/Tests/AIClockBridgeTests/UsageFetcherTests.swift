import XCTest
@testable import AIClockBridge

final class UsageFetcherTests: XCTestCase {
    func testRemainingPercentUsesUsedValueOnlyForPresentation() {
        XCTAssertEqual(remainingPercent(fromUsed: 0), 100)
        XCTAssertEqual(remainingPercent(fromUsed: 10), 90)
        XCTAssertEqual(remainingPercent(fromUsed: 100), 0)
        XCTAssertEqual(remainingPercent(fromUsed: 120), 0)
        XCTAssertNil(remainingPercent(fromUsed: nil))
        XCTAssertNil(remainingPercent(fromUsed: -1))
    }

    func testCursorAutoOnlyUsesDisplayedAPIRemainingAndRequiresAuto() {
        XCTAssertTrue(shouldShowOnlyCursorAuto(apiUsedPct: 100, autoUsedPct: 40))
        XCTAssertTrue(shouldShowOnlyCursorAuto(apiUsedPct: 99.51, autoUsedPct: 40))
        XCTAssertFalse(shouldShowOnlyCursorAuto(apiUsedPct: 99.5, autoUsedPct: 40))
        XCTAssertFalse(shouldShowOnlyCursorAuto(apiUsedPct: 99, autoUsedPct: 40))
        XCTAssertFalse(shouldShowOnlyCursorAuto(apiUsedPct: 100, autoUsedPct: nil))
        XCTAssertFalse(shouldShowOnlyCursorAuto(apiUsedPct: nil, autoUsedPct: 40))
    }

    func testCursorRingFollowsAutoOnlyWhenAPIIsDisplayedAsZero() {
        XCTAssertEqual(cursorRingRemainingPercent(totalUsedPct: 100, autoUsedPct: 40,
                                                  apiUsedPct: 100), 60)
        XCTAssertEqual(cursorRingRemainingPercent(totalUsedPct: 75, autoUsedPct: 40,
                                                  apiUsedPct: 99), 25)
        XCTAssertEqual(cursorRingRemainingPercent(totalUsedPct: 100, autoUsedPct: nil,
                                                  apiUsedPct: 100), 0)
    }

    func testCursorRingExhaustionMatchesFirmwareThreshold() {
        XCTAssertTrue(isCursorRingExhausted(remainingPct: 0.1))
        XCTAssertFalse(isCursorRingExhausted(remainingPct: 0.1001))
    }

    func testProLitePrimaryWindowIsClassifiedAsWeeklyByDuration() {
        let rateLimit: [String: Any] = [
            "primary_window": [
                "used_percent": 10,
                "limit_window_seconds": 604_800,
                "reset_at": 1_604_800,
            ],
        ]
        let usage = UsageFetcher.parseCodexRateLimit(rateLimit, now: 1_000_000)

        XCTAssertNil(usage.primaryPct)
        XCTAssertNil(usage.primaryWindowMin)
        XCTAssertEqual(usage.weeklyPct, 10)
        XCTAssertEqual(usage.weeklyWindowMin, 10_080)
        XCTAssertEqual(usage.weeklyResetMin, 10_080)
    }

    func testStandardDualWindowsKeepFiveHourAndWeeklySlots() {
        let rateLimit: [String: Any] = [
            "primary_window": ["used_percent": 20, "limit_window_seconds": 18_000],
            "secondary_window": ["used_percent": 30, "limit_window_seconds": 604_800],
        ]
        let usage = UsageFetcher.parseCodexRateLimit(rateLimit, now: 1_000_000)

        XCTAssertEqual(usage.primaryPct, 20)
        XCTAssertEqual(usage.primaryWindowMin, 300)
        XCTAssertEqual(usage.weeklyPct, 30)
        XCTAssertEqual(usage.weeklyWindowMin, 10_080)
    }

    func testCursorJSONUsesDirectTotalAutoAndAPIPercentages() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "billingCycleEnd": "1003600",
            "planUsage": ["totalPercentUsed": 29, "autoPercentUsed": 14, "apiPercentUsed": 77],
        ])
        let usage = UsageFetcher.parseCursorCurrentPeriodUsage(data, now: 1_000_000)
        XCTAssertEqual(usage?.totalPct, 29)
        XCTAssertEqual(usage?.autoPct, 14)
        XCTAssertEqual(usage?.apiPct, 77)
        XCTAssertEqual(usage?.billingResetMin, 60)
        XCTAssertEqual(remainingPercent(fromUsed: usage?.totalPct), 71)
        XCTAssertEqual(remainingPercent(fromUsed: usage?.autoPct), 86)
        XCTAssertEqual(remainingPercent(fromUsed: usage?.apiPct), 23)
    }

    func testCursorTotalIsRequiredButAutoAndAPIAreOptional() throws {
        let noTotal = try JSONSerialization.data(withJSONObject: [
            "planUsage": ["autoPercentUsed": 14, "apiPercentUsed": 77],
        ])
        XCTAssertNil(UsageFetcher.parseCursorCurrentPeriodUsage(noTotal))

        let totalOnly = try JSONSerialization.data(withJSONObject: [
            "plan_usage": ["total_percent_used": 29],
        ])
        let usage = UsageFetcher.parseCursorCurrentPeriodUsage(totalOnly)
        XCTAssertEqual(usage?.totalPct, 29)
        XCTAssertNil(usage?.autoPct)
        XCTAssertNil(usage?.apiPct)
    }

    func testCursorProtobufParserReadsOptionalDoubleFields() {
        var plan = Data()
        appendFixed64(field: 12, value: 14, to: &plan)
        appendFixed64(field: 13, value: 77, to: &plan)
        appendFixed64(field: 14, value: 29, to: &plan)
        var outer = Data([0x10]) // billing_cycle_end, varint
        appendVarint(1_003_600, to: &outer)
        outer.append(0x1a) // plan_usage, length-delimited
        appendVarint(UInt64(plan.count), to: &outer)
        outer.append(plan)

        let usage = UsageFetcher.parseCursorCurrentPeriodUsage(outer, now: 1_000_000)
        XCTAssertEqual(usage?.totalPct, 29)
        XCTAssertEqual(usage?.autoPct, 14)
        XCTAssertEqual(usage?.apiPct, 77)
        XCTAssertEqual(usage?.billingResetMin, 60)
    }

    func testProviderEligibilityAndStalenessBoundaries() {
        let now = Date(timeIntervalSince1970: 10_000)
        var usage = ProviderUsage()
        usage.checkCompleted = true
        XCTAssertFalse(usage.isEligible(now: now))
        XCTAssertTrue(usage.isLoggedOut)

        usage.credentialPresent = true
        usage.fetchedAt = now.addingTimeInterval(-16 * 60)
        XCTAssertFalse(usage.isEligible(now: now), "credentials alone must not enter rotation")
        usage.primaryPct = 25
        XCTAssertTrue(usage.isEligible(now: now))
        XCTAssertTrue(usage.isStale(now: now))

        usage.fetchedAt = now.addingTimeInterval(-6 * 60 * 60 - 1)
        XCTAssertFalse(usage.isEligible(now: now))
    }

    private func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }

    private func appendFixed64(field: UInt8, value: Double, to data: inout Data) {
        data.append((field << 3) | 1)
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}
