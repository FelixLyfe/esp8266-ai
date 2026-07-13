using System.Runtime.InteropServices;

namespace AIClockBridge;

// System-wide CPU% for the dedicated CPU page (device + mirror). CPU comes
// from GetSystemTimes deltas and recomputes at most once per second.
static class SystemStatsMonitor
{
    static readonly object Lock = new();
    static ulong _lastBusy, _lastIdle;
    static bool _hasLast;
    static int _cached;
    static DateTime _cachedAt = DateTime.MinValue;

    public static int CpuPercent()
    {
        lock (Lock)
        {
            if ((DateTime.UtcNow - _cachedAt).TotalSeconds < 1.0) return _cached;
            _cachedAt = DateTime.UtcNow;

            if (GetSystemTimes(out var idleFt, out var kernelFt, out var userFt))
            {
                var idle = ToUlong(idleFt);
                // kernel time includes idle time, so busy = (kernel - idle) + user
                var busy = ToUlong(kernelFt) - idle + ToUlong(userFt);
                if (_hasLast)
                {
                    var dBusy = busy - _lastBusy;
                    var dTotal = dBusy + (idle - _lastIdle);
                    if (dTotal > 0) _cached = (int)Math.Round(dBusy * 100.0 / dTotal);
                }
                _lastBusy = busy;
                _lastIdle = idle;
                _hasLast = true;
            }

            return _cached;
        }
    }

    public static byte[] ToJson() =>
        System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
        {
            ["cpu_pct"] = CpuPercent(),
        });

    static ulong ToUlong(System.Runtime.InteropServices.ComTypes.FILETIME ft) =>
        ((ulong)(uint)ft.dwHighDateTime << 32) | (uint)ft.dwLowDateTime;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetSystemTimes(
        out System.Runtime.InteropServices.ComTypes.FILETIME idleTime,
        out System.Runtime.InteropServices.ComTypes.FILETIME kernelTime,
        out System.Runtime.InteropServices.ComTypes.FILETIME userTime);

}
