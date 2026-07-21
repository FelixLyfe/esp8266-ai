using System.Text;
using AIClockBridge;

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

Require(USBFrame.Crc32(Encoding.ASCII.GetBytes("123456789")) == 0xCBF4_3926,
    "CRC32 reference vector failed");

var original = new USBFrame(USBMessage.Clock, 0x1234,
    Encoding.UTF8.GetBytes("{\"time\":\"12:34:56\",\"date\":\"2026-07-14\",\"weekday\":\"TUE\"}"));
var noisy = new List<byte> { 0x00, 0xFF, 0xA5 };
noisy.AddRange(original.Encode());
Require(USBFrame.TryDecode(noisy, out var decoded), "frame did not decode");
Require(decoded.Type == original.Type && decoded.Sequence == original.Sequence
        && decoded.Payload.SequenceEqual(original.Payload), "roundtrip mismatch");

var corrupt = new USBFrame(USBMessage.Heartbeat, 1, Array.Empty<byte>()).Encode();
corrupt[8] ^= 0x01;
var valid = new USBFrame(USBMessage.HeartbeatAck, 2, Array.Empty<byte>()).Encode();
var stream = corrupt.Concat(valid).ToList();
Require(USBFrame.TryDecode(stream, out decoded) && decoded.Type == USBMessage.HeartbeatAck,
    "decoder did not recover after corrupt frame");

Require(CursorQuotaPolicy.ShouldShowAutoOnly(100, 40),
    "exhausted Cursor API quota did not select Auto-only display");
Require(CursorQuotaPolicy.ShouldShowAutoOnly(99.51, 40),
    "API quota that displays as zero did not select Auto-only display");
Require(!CursorQuotaPolicy.ShouldShowAutoOnly(99.5, 40),
    "API quota that displays as one selected Auto-only display");
Require(!CursorQuotaPolicy.ShouldShowAutoOnly(100, null),
    "missing Auto quota must preserve the existing fallback");
Require(CursorQuotaPolicy.RingRemainingPercent(100, 40, 100) == 60,
    "Cursor ring did not follow Auto quota in Auto-only mode");
Require(CursorQuotaPolicy.RingRemainingPercent(75, 40, 99) == 25,
    "Cursor ring did not preserve Total quota outside Auto-only mode");
Require(CursorQuotaPolicy.IsRingExhausted(0.1),
    "Cursor ring exhaustion threshold no longer matches firmware");
Require(!CursorQuotaPolicy.IsRingExhausted(0.1001),
    "Cursor ring turned red above the firmware exhaustion threshold");

var standardTime = ClockSnapshot.Current(new DateTimeOffset(2026, 1, 15, 12, 0, 0, TimeSpan.Zero));
Require(standardTime.Time == "04:00:00" && standardTime.Date == "2026-01-15"
        && standardTime.Weekday == "THU",
    "San Francisco standard-time conversion failed");
var daylightTime = ClockSnapshot.Current(new DateTimeOffset(2026, 7, 15, 12, 0, 0, TimeSpan.Zero));
Require(daylightTime.Time == "05:00:00" && daylightTime.Date == "2026-07-15"
        && daylightTime.Weekday == "WED",
    "San Francisco daylight-saving conversion failed");
using (var clockJson = System.Text.Json.JsonDocument.Parse(daylightTime.ToJson()))
{
    var root = clockJson.RootElement;
    Require(root.GetProperty("zone").GetString() == "America/Los_Angeles"
            && root.GetProperty("zone_time").GetString() == "05:00:00"
            && root.TryGetProperty("time", out _),
        "clock payload compatibility fields are missing");
}

Console.WriteLine("USB protocol smoke tests passed");
