import Darwin
import Foundation

/// Reports the Mac's currently active physical network. `ipconfig getsummary`
/// exposes the associated Wi-Fi SSID even when CoreWLAN redacts it; the value
/// is cached so this never becomes part of the 4 Hz throughput hot path.
final class NetworkNameMonitor {
    static let shared = NetworkNameMonitor()

    private let lock = NSLock()
    private var cached = "Not connected"
    private var cachedAt = Date.distantPast

    func currentName() -> String {
        let now = Date()
        lock.lock()
        if now.timeIntervalSince(cachedAt) < 30 {
            let value = cached
            lock.unlock()
            return value
        }
        cachedAt = now // reserves this refresh so another queue returns the prior value
        lock.unlock()

        let resolved = Self.resolveName()
        lock.lock()
        cached = resolved
        lock.unlock()
        return resolved
    }

    private static func resolveName() -> String {
        let active = Self.activePhysicalInterfaces()
        for name in active {
            let summary = Self.ipconfigSummary(name)
            if let ssid = Self.value(named: "SSID", in: summary), !ssid.isEmpty {
                return ssid
            }
        }
        if let name = active.first {
            return "Ethernet \(name)"
        }
        return "Not connected"
    }

    /// TFT_eSPI's built-in fonts are ASCII-only. Preserve the exact name in
    /// the Mac mirror, but transliterate the value sent to the device so a
    /// non-Latin SSID never turns into an empty row on the physical screen.
    func deviceName() -> String {
        let raw = currentName()
        if raw.unicodeScalars.allSatisfy(\.isASCII) { return raw }
        let latin = raw.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? raw
        var ascii = ""
        for scalar in latin.unicodeScalars where scalar.isASCII {
            ascii.unicodeScalars.append(scalar)
        }
        let value = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Wi-Fi connected" : value
    }

    private static func activePhysicalInterfaces() -> [String] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }
        var result: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let rawName = ifa.ifa_name else { continue }
            let name = String(cString: rawName)
            let flags = Int32(ifa.ifa_flags)
            guard name.hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  !result.contains(name) else { continue }
            result.append(name)
        }
        return result.sorted()
    }

    private static func ipconfigSummary(_ interface: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        process.arguments = ["getsummary", interface]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        } catch {
            return ""
        }
    }

    private static func value(named key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
