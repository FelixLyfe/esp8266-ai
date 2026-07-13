using System.Net.NetworkInformation;
using System.Text.Json;

namespace AIClockBridge;

// Samples this PC's real up/down throughput 4x per second from the OS
// per-interface byte counters (NetworkInterface.GetIPStatistics, same source
// Task Manager uses). Only physical Ethernet/WiFi adapters are summed so
// VPN/loopback/virtual traffic isn't double counted. Keeps a ring of the last
// 3 minutes; the mirror chart and the ESP8266 (via GET /net) both read it.
sealed class NetSpeedMonitor
{
    public readonly record struct Sample(double Rx, double Tx); // bytes/sec

    /// 4 samples per second: enough temporal resolution that the device's
    /// 250ms-per-step sweep animates smoothly instead of jumping once a second.
    public const double SampleInterval = 0.25;

    readonly object _lock = new();
    readonly List<Sample> _samples = new();
    int _totalSamples; // monotonically increasing seq for /net consumers
    long? _lastRx;
    long? _lastTx;
    DateTime? _lastAt;
    System.Threading.Timer _timer;

    const int Capacity = 720; // 3 minutes at 4Hz

    public void Start()
    {
        SampleNow();
        _timer = new System.Threading.Timer(_ => SampleNow(), null,
            TimeSpan.FromSeconds(SampleInterval), TimeSpan.FromSeconds(SampleInterval));
    }

    /// Most recent `count` samples, oldest first.
    public Sample[] History(int count)
    {
        lock (_lock)
        {
            var skip = Math.Max(0, _samples.Count - count);
            return _samples.Skip(skip).ToArray();
        }
    }

    /// Latest instantaneous sample (may be spiky at 4Hz).
    public Sample Current
    {
        get { lock (_lock) return _samples.Count > 0 ? _samples[^1] : default; }
    }

    /// 1-second average — what the DL/UL readout shows (4Hz raw is too jumpy).
    public Sample CurrentSmoothed
    {
        get
        {
            var recent = History(4);
            if (recent.Length == 0) return default;
            return new Sample(recent.Average(s => s.Rx), recent.Average(s => s.Tx));
        }
    }

    /// JSON for the ESP8266: smoothed current speeds + an incremental tail of
    /// recent samples. `seq` is the total sample count; the device remembers
    /// the last seq it consumed and appends only the new entries, so its sweep
    /// runs at the true 4Hz cadence regardless of how often it polls.
    public byte[] ToJson(string networkName)
    {
        int seq;
        Sample[] tail;
        lock (_lock)
        {
            seq = _totalSamples;
            var skip = Math.Max(0, _samples.Count - 12);
            tail = _samples.Skip(skip).ToArray();
        }
        var smoothed = CurrentSmoothed;
        var dict = new Dictionary<string, object>
        {
            ["rx_bps"] = (long)smoothed.Rx,
            ["tx_bps"] = (long)smoothed.Tx,
            ["network_name"] = networkName,
            ["seq"] = seq,
            ["interval_ms"] = (int)(SampleInterval * 1000),
            ["rx"] = tail.Select(s => (long)s.Rx).ToArray(),
            ["tx"] = tail.Select(s => (long)s.Tx).ToArray(),
        };
        return JsonSerializer.SerializeToUtf8Bytes(dict);
    }

    public static string FormatSpeed(double bps)
    {
        if (bps >= 1_000_000) return $"{bps / 1_000_000:F1} MB/s";
        if (bps >= 1_000) return $"{bps / 1_000:F0} KB/s";
        return $"{bps:F0} B/s";
    }

    void SampleNow()
    {
        var (rx, tx) = Counters();
        var now = DateTime.UtcNow;
        var lr = _lastRx;
        var lt = _lastTx;
        var la = _lastAt;
        _lastRx = rx;
        _lastTx = tx;
        _lastAt = now;
        if (!lr.HasValue || !lt.HasValue || !la.HasValue) return;
        var dt = (now - la.Value).TotalSeconds;
        if (dt <= 0.2) return;
        // counters can reset when an adapter bounces; treat negatives as zero
        var dRx = Math.Max(0, rx - lr.Value);
        var dTx = Math.Max(0, tx - lt.Value);
        var sample = new Sample(dRx / dt, dTx / dt);
        lock (_lock)
        {
            _samples.Add(sample);
            _totalSamples++;
            if (_samples.Count > Capacity) _samples.RemoveRange(0, _samples.Count - Capacity);
        }
    }

    static (long, long) Counters()
    {
        long rx = 0, tx = 0;
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType != NetworkInterfaceType.Ethernet
                    && nic.NetworkInterfaceType != NetworkInterfaceType.Wireless80211) continue;
                var desc = nic.Description.ToLowerInvariant();
                // skip common virtual adapters that report as Ethernet
                if (desc.Contains("virtual") || desc.Contains("vpn") || desc.Contains("tap")
                    || desc.Contains("hyper-v") || desc.Contains("vmware")
                    || desc.Contains("loopback") || desc.Contains("wintun")) continue;
                var stats = nic.GetIPStatistics();
                rx += stats.BytesReceived;
                tx += stats.BytesSent;
            }
        }
        catch
        {
            // adapter enumeration can transiently fail; keep last counters
        }
        return (rx, tx);
    }
}
