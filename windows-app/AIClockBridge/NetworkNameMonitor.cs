using System.Diagnostics;
using System.Net.NetworkInformation;

namespace AIClockBridge;

/// Reports the active Wi-Fi SSID, with an Ethernet adapter fallback. The
/// result is cached because netsh is far too expensive for the 4 Hz net loop.
sealed class NetworkNameMonitor
{
    public static readonly NetworkNameMonitor Shared = new();

    readonly object _lock = new();
    string _cached = "Not connected";
    DateTime _cachedAt = DateTime.MinValue;

    public string CurrentName()
    {
        lock (_lock)
        {
            if (DateTime.UtcNow - _cachedAt < TimeSpan.FromSeconds(30)) return _cached;
            _cachedAt = DateTime.UtcNow;
        }
        var resolved = ResolveName();
        lock (_lock) _cached = resolved;
        return resolved;
    }

    /// The firmware's built-in font is ASCII-only. Keep the exact name in the
    /// Windows mirror but strip unsupported characters on the wire.
    public string DeviceName()
    {
        var raw = CurrentName();
        if (raw.All(c => c <= 0x7f)) return raw;
        var ascii = new string(raw.Where(c => c <= 0x7f).ToArray()).Trim();
        return ascii.Length == 0 ? "Wi-Fi connected" : ascii;
    }

    static string ResolveName()
    {
        try
        {
            var start = new ProcessStartInfo
            {
                FileName = "netsh.exe",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            start.ArgumentList.Add("wlan");
            start.ArgumentList.Add("show");
            start.ArgumentList.Add("interfaces");
            using var process = Process.Start(start);
            if (process != null)
            {
                var output = process.StandardOutput.ReadToEnd();
                if (process.WaitForExit(3000) && process.ExitCode == 0)
                {
                    foreach (var line in output.Split('\n'))
                    {
                        var parts = line.Split(':', 2);
                        if (parts.Length == 2 && parts[0].Trim().Equals("SSID", StringComparison.OrdinalIgnoreCase))
                        {
                            var value = parts[1].Trim();
                            if (value.Length > 0) return value;
                        }
                    }
                }
                else if (!process.HasExited) process.Kill();
            }
        }
        catch
        {
            // netsh may be unavailable when WLAN support is not installed
        }

        try
        {
            var active = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(nic =>
                nic.OperationalStatus == OperationalStatus.Up
                && (nic.NetworkInterfaceType == NetworkInterfaceType.Ethernet
                    || nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
                && !IsVirtual(nic.Description));
            if (active != null) return $"Ethernet {active.Name}";
        }
        catch
        {
            // transient adapter enumeration failure
        }
        return "Not connected";
    }

    static bool IsVirtual(string description)
    {
        var value = description.ToLowerInvariant();
        return value.Contains("virtual") || value.Contains("vpn") || value.Contains("tap")
            || value.Contains("hyper-v") || value.Contains("vmware") || value.Contains("loopback")
            || value.Contains("wintun");
    }
}
