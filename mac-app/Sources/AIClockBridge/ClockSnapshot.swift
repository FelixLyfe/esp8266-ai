import Foundation

struct ClockSnapshot {
    private static let zoneIdentifier = "America/Los_Angeles"
    private static let sanFranciscoTimeZone = TimeZone(identifier: "America/Los_Angeles")!

    let time: String
    let date: String
    let weekday: String
    private let legacyTime: String
    private let legacyDate: String
    private let legacyWeekday: String

    static func current(at value: Date = Date()) -> ClockSnapshot {
        let sanFrancisco = formatted(value, in: sanFranciscoTimeZone)
        let local = formatted(value, in: .current)
        return ClockSnapshot(time: sanFrancisco.time, date: sanFrancisco.date,
                             weekday: sanFrancisco.weekday, legacyTime: local.time,
                             legacyDate: local.date, legacyWeekday: local.weekday)
    }

    private static func formatted(_ value: Date, in timeZone: TimeZone)
        -> (time: String, date: String, weekday: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday],
                                            from: value)
        let weekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        let weekdayIndex = max(1, min(7, parts.weekday ?? 1)) - 1
        return (
            String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0),
            String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
            weekdays[weekdayIndex]
        )
    }

    func jsonData() -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "time": legacyTime,
            "date": legacyDate,
            "weekday": legacyWeekday,
            "zone": Self.zoneIdentifier,
            "zone_time": time,
            "zone_date": date,
            "zone_weekday": weekday,
        ])) ?? Data("{}".utf8)
    }
}
