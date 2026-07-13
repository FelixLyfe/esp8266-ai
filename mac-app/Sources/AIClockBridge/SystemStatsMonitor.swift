import Foundation

// System-wide CPU% for the dedicated CPU page (device + mirror).
// CPU comes from HOST_CPU_LOAD_INFO tick deltas between calls and recomputes
// at most once per second no matter how often it is requested.
final class SystemStatsMonitor {
    static let shared = SystemStatsMonitor()

    private let lock = NSLock()
    private var lastTicks: (busy: UInt64, idle: UInt64)?
    private var cachedCPU = 0
    private var cachedAt = Date.distantPast

    func cpuPercent() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(cachedAt) < 1.0 { return cachedCPU }
        cachedAt = Date()
        if let ticks = Self.cpuTicks() {
            let busy = ticks.user + ticks.system + ticks.nice
            if let last = lastTicks {
                let dBusy = busy &- last.busy
                let dIdle = ticks.idle &- last.idle
                let total = dBusy + dIdle
                if total > 0 { cachedCPU = Int((Double(dBusy) / Double(total) * 100).rounded()) }
            } else {
                let total = busy + ticks.idle
                if total > 0 { cachedCPU = Int((Double(busy) / Double(total) * 100).rounded()) }
            }
            lastTicks = (busy, ticks.idle)
        }
        return cachedCPU
    }

    func jsonData() -> Data {
        let value = cpuPercent()
        return (try? JSONSerialization.data(withJSONObject: ["cpu_pct": value])) ?? Data("{}".utf8)
    }

    private static func cpuTicks() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks // (USER, SYSTEM, IDLE, NICE)
        return (UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3))
    }
}
