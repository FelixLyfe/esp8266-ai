import AppKit
import XCTest
@testable import AIClockBridge

final class SerialLinkTests: XCTestCase {
    func testCommonModeTimerFiresWhileMenuTrackingModeIsActive() {
        _ = NSApplication.shared
        var fireCount = 0
        let timer = SerialLink.scheduleLoopTimer(interval: 0.01) {
            fireCount += 1
        }
        defer { timer.invalidate() }

        let deadline = Date().addingTimeInterval(0.25)
        while fireCount == 0, Date() < deadline {
            _ = RunLoop.main.run(mode: .eventTracking, before: deadline)
        }

        XCTAssertGreaterThan(fireCount, 0,
                             "USB heartbeat timer must keep running while an NSMenu is open")
    }
}
