using System.Text.Json;

namespace AIClockBridge;

readonly record struct ClockSnapshot(string Time, string Date, string Weekday)
{
    public static ClockSnapshot Current()
    {
        var now = DateTime.Now;
        return new ClockSnapshot(now.ToString("HH:mm:ss"), now.ToString("yyyy-MM-dd"),
            now.ToString("ddd", System.Globalization.CultureInfo.InvariantCulture).ToUpperInvariant());
    }

    public byte[] ToJson() => JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string>
    {
        ["time"] = Time,
        ["date"] = Date,
        ["weekday"] = Weekday,
    });
}
