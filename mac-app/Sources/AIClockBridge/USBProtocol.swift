import Foundation

enum USBMessage: UInt8 {
    case hello = 0x01
    case helloAck = 0x02
    case heartbeat = 0x03
    case heartbeatAck = 0x04
    case status = 0x10
    case clock = 0x13
    case getInfo = 0x20
    case deviceInfo = 0x21
    case command = 0x22
    case getResource = 0x23
    case resourceBegin = 0x30
    case resourceChunk = 0x31
    case resourceEnd = 0x32
    case ack = 0x7E
}

enum USBResource: UInt8 {
    case claudeGif = 3
    case codexGif = 4
    case claudeSprite = 5
    case codexSprite = 6
}

struct USBFrame {
    static let magic0: UInt8 = 0xA5
    static let magic1: UInt8 = 0x5A
    static let version: UInt8 = 1
    static let maxPayload = 1024

    let type: USBMessage
    let sequence: UInt16
    let payload: Data

    func encoded() -> Data {
        precondition(payload.count <= Self.maxPayload)
        var data = Data([Self.magic0, Self.magic1, Self.version, type.rawValue,
                         UInt8(sequence & 0xFF), UInt8(sequence >> 8),
                         UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)])
        data.append(payload)
        let crc = Self.crc32(data.dropFirst(2))
        data.append(UInt8(crc & 0xFF))
        data.append(UInt8((crc >> 8) & 0xFF))
        data.append(UInt8((crc >> 16) & 0xFF))
        data.append(UInt8((crc >> 24) & 0xFF))
        return data
    }

    /// Pulls one valid frame from a noisy UART stream. Boot ROM/debug bytes are
    /// discarded until the two-byte magic is found; a corrupt frame advances by
    /// one byte so a later frame can still be recovered.
    static func decode(from buffer: inout Data) -> USBFrame? {
        func byte(_ offset: Int) -> UInt8 { buffer[buffer.index(buffer.startIndex, offsetBy: offset)] }
        while buffer.count >= 2 && (byte(0) != magic0 || byte(1) != magic1) {
            buffer.removeFirst()
        }
        guard buffer.count >= 8 else { return nil }
        guard byte(2) == version, let type = USBMessage(rawValue: byte(3)) else {
            buffer.removeFirst()
            return decode(from: &buffer)
        }
        let length = Int(byte(6)) | (Int(byte(7)) << 8)
        guard length <= maxPayload else {
            buffer.removeFirst()
            return decode(from: &buffer)
        }
        let total = 8 + length + 4
        guard buffer.count >= total else { return nil }
        let expected = UInt32(byte(8 + length))
            | (UInt32(byte(9 + length)) << 8)
            | (UInt32(byte(10 + length)) << 16)
            | (UInt32(byte(11 + length)) << 24)
        let crcStart = buffer.index(buffer.startIndex, offsetBy: 2)
        let crcEnd = buffer.index(buffer.startIndex, offsetBy: 8 + length)
        let actual = crc32(buffer[crcStart..<crcEnd])
        guard expected == actual else {
            buffer.removeFirst()
            return decode(from: &buffer)
        }
        let sequence = UInt16(byte(4)) | (UInt16(byte(5)) << 8)
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 8)
        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeFirst(total)
        return USBFrame(type: type, sequence: sequence, payload: payload)
    }

    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else { return nil }
        return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
