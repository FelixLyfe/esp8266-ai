import Foundation

struct ClockSnapshot {
    let time: String
    let date: String
    let weekday: String

    static func current(at value: Date = Date()) -> ClockSnapshot {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday],
                                                    from: value)
        let weekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        let weekdayIndex = max(1, min(7, parts.weekday ?? 1)) - 1
        return ClockSnapshot(
            time: String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0),
            date: String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
            weekday: weekdays[weekdayIndex]
        )
    }

    func jsonData() -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "time": time,
            "date": date,
            "weekday": weekday,
        ])) ?? Data("{}".utf8)
    }
}
