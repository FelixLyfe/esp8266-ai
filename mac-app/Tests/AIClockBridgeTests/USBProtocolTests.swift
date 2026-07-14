import Foundation
import XCTest
@testable import AIClockBridge

final class USBProtocolTests: XCTestCase {
    func testCRC32ReferenceVector() {
        XCTAssertEqual(USBFrame.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testFrameRoundTripAfterNoise() {
        let original = USBFrame(type: .clock, sequence: 0x1234,
                                payload: Data("{\"time\":\"12:34:56\",\"date\":\"2026-07-14\",\"weekday\":\"TUE\"}".utf8))
        var stream = Data([0x00, 0xFF, 0xA5, 0x00])
        stream.append(original.encoded())
        let decoded = USBFrame.decode(from: &stream)
        XCTAssertEqual(decoded?.type, .clock)
        XCTAssertEqual(decoded?.sequence, 0x1234)
        XCTAssertEqual(decoded?.payload, original.payload)
        XCTAssertTrue(stream.isEmpty)
    }

    func testCorruptFrameIsSkipped() {
        var corrupt = USBFrame(type: .heartbeat, sequence: 1, payload: Data()).encoded()
        corrupt[corrupt.count - 1] ^= 0xFF
        corrupt.append(USBFrame(type: .heartbeatAck, sequence: 2, payload: Data()).encoded())
        let decoded = USBFrame.decode(from: &corrupt)
        XCTAssertEqual(decoded?.type, .heartbeatAck)
        XCTAssertEqual(decoded?.sequence, 2)
    }
}
