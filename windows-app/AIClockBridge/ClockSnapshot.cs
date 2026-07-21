using System.Text.Json;

namespace AIClockBridge;

readonly record struct ClockSnapshot
{
    static readonly TimeZoneInfo SanFranciscoTimeZone = ResolveSanFranciscoTimeZone();
    public string Time { get; }
    public string Date { get; }
    public string Weekday { get; }
    readonly string _legacyTime;
    readonly string _legacyDate;
    readonly string _legacyWeekday;

    ClockSnapshot(string time, string date, string weekday,
                  string legacyTime, string legacyDate, string legacyWeekday)
    {
        Time = time;
        Date = date;
        Weekday = weekday;
        _legacyTime = legacyTime;
        _legacyDate = legacyDate;
        _legacyWeekday = legacyWeekday;
    }

    public static ClockSnapshot Current(DateTimeOffset? value = null)
    {
        var instant = value ?? DateTimeOffset.UtcNow;
        var sanFrancisco = TimeZoneInfo.ConvertTime(instant, SanFranciscoTimeZone);
        var local = TimeZoneInfo.ConvertTime(instant, TimeZoneInfo.Local);
        return new ClockSnapshot(FormatTime(sanFrancisco), FormatDate(sanFrancisco), FormatWeekday(sanFrancisco),
            FormatTime(local), FormatDate(local), FormatWeekday(local));
    }

    static TimeZoneInfo ResolveSanFranciscoTimeZone()
    {
        foreach (var id in new[] { "America/Los_Angeles", "Pacific Standard Time" })
        {
            try { return TimeZoneInfo.FindSystemTimeZoneById(id); }
            catch (TimeZoneNotFoundException) { }
            catch (InvalidTimeZoneException) { }
        }
        throw new TimeZoneNotFoundException("San Francisco time zone is unavailable");
    }

    static string FormatTime(DateTimeOffset value) => value.ToString("HH:mm:ss");
    static string FormatDate(DateTimeOffset value) => value.ToString("yyyy-MM-dd");
    static string FormatWeekday(DateTimeOffset value) =>
        value.ToString("ddd", System.Globalization.CultureInfo.InvariantCulture).ToUpperInvariant();

    public byte[] ToJson() => JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string>
    {
        ["time"] = _legacyTime,
        ["date"] = _legacyDate,
        ["weekday"] = _legacyWeekday,
        ["zone"] = "America/Los_Angeles",
        ["zone_time"] = Time,
        ["zone_date"] = Date,
        ["zone_weekday"] = Weekday,
    });
}
